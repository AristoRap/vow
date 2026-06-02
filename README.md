# vow

[![CI](https://github.com/AristoRap/vow/actions/workflows/ci.yml/badge.svg)](https://github.com/AristoRap/vow/actions/workflows/ci.yml)
[![Latest tag](https://img.shields.io/github/v/tag/AristoRap/vow?label=release&sort=semver)](https://github.com/AristoRap/vow/tags)

Vow generates a typed client — TypeScript, or JavaScript plus a `.d.ts` — from
your annotated Crystal methods, so the frontend can call them with the arguments
and return types checked.

```crystal
class API
  include Vow::Exportable

  @[Vow::Export]
  def greet(name : String) : String
    "Hello, #{name}!"
  end
end
```

```ts
// generated client, called from TypeScript:
await api.API.greet({ name: "world" }); // => "Hello, world!", typed as Promise<string>
```

Vow does not include a server and does not move data over the network. It
generates the client, and on the Crystal side it turns a `(method name, JSON
arguments)` pair into a JSON result. You write the bit in the middle that
carries the call from the frontend to your backend (HTTP, a CLI, a test —
whatever you want).

## How it works

`@[Vow::Export]` on its own does nothing — it's just a marker. The work happens
because you `include Vow::Exportable`, which adds macros to your class. At compile
time those macros read every method you marked and generate:

- **Dispatch glue.** For each method, a callback that reads the named arguments,
  decodes each into the type you declared (applying defaults for omitted
  optional args, erroring on a missing required one), calls the method, and
  encodes the result back to JSON. This is what `Vow::Registry#dispatch` runs.
- **A manifest.** A static description of each method — its name, argument
  names and types, and return type — plus any custom types they use. This can be
  read without creating an instance of your class, and it's what the code
  generator turns into the client (TypeScript or JavaScript).

The macros also check, at compile time, that every exported method has typed
arguments and a declared return type. If one doesn't, the build fails with a
message naming the method. Vow needs the types to generate the client and won't
guess.

So there's one source — your annotated methods — feeding two paths: dispatching
real calls at runtime, and generating the typed client.

## Install

**As a library** — to call Vow from Crystal (dispatch, manifest, the codegen
API) — add it to your `shard.yml` and run `shards install`:

```yaml
dependencies:
  vow:
    github: AristoRap/vow
```

**As the `vow` CLI** — to run `vow gen` from a shell — build the binary and put
it on your `PATH`:

```bash
git clone https://github.com/AristoRap/vow && cd vow
shards install
make build      # runs the specs, then `shards build` → ./bin/vow
make copy       # installs it to /usr/local/bin/vow
```

`make deploy` does a `--release` build then `copy` in one step. Throughout this
README, `vow` means that binary on your `PATH`; to skip installing it, run it in
place as `./bin/vow …`.

## Usage

### 1. Mark your methods

`include Vow::Exportable` in a class, then put `@[Vow::Export]` on each method you
want to expose:

```crystal
require "vow"

class API
  include Vow::Exportable

  @[Vow::Export]                       # exposed as "API.greet"
  def greet(name : String) : String
    "Hello, #{name}!"
  end

  @[Vow::Export(name: "math.add")]     # use a custom name instead
  def add(a : Int32, b : Int32) : Int32
    a + b
  end
end
```

The one rule Vow enforces is that every argument and the return type is typed
(write `: Nil` for a method that returns nothing). Beyond that, the signature is
honored as written — required args, defaults, nilable types, named-only args
(after a bare `*`), and external argument names all carry through 1-to-1. An arg
with a default value is optional: the caller may omit it.

```crystal
@[Vow::Export]
def shout(name : String, excitement : Int32 = 1) : String   # excitement is optional
  "Hey #{name}" + "!" * excitement
end
```

#### Opts: an opaque side channel for transports

Any keyword on `@[Vow::Export]` other than the reserved `name:` and `skip:` is
swept into an opaque **opts** bag, carried into the manifest and the generated
client **verbatim**. Vow validates nothing and attaches no meaning to any key —
it just hands the bag to your transport, which decides what (if anything) the
keys mean. Each value keeps its literal type (`:get` → the string `"get"`, `30` →
the number `30`, `true` → the boolean `true`), so it round-trips faithfully.

The canonical example is `verb`, which the bundled HTTP client reads to route a
side-effect-free **read** as a cacheable GET (it treats a missing `verb` as
`"post"`):

```crystal
@[Vow::Export(verb: :get)]
def find(id : Int32) : User   # the HTTP transport sends GET — a browser/CDN can cache it
  # ...
end
```

But `verb` is not special to Vow — it's just one opt. Add whatever your transport
understands; they ride along untouched:

```crystal
@[Vow::Export(verb: :get, cache: 30, scope: "admin")]
def report(id : Int32) : Report   # opts: { verb: "get", cache: 30, scope: "admin" }
  # ...
end
```

A transport that knows none of these keys ignores the whole bag — Vow itself
never sets a header, builds a URL, or branches on an opt. The one piece of code
that reads `verb` is the bundled HTTP client, because routing GET vs POST is _its_
job, not Vow's.

#### Exporting every method

If a class is meant to be exposed wholesale, `include Vow::Exportable::All`
instead and skip the per-method annotation — every public method is exported:

```crystal
class API
  include Vow::Exportable::All

  def greet(name : String) : String     # exposed as "API.greet", no annotation
    "Hello, #{name}!"
  end

  @[Vow::Export(name: "math.add")]       # annotation is optional — here, to rename
  def add(a : Int32, b : Int32) : Int32
    a + b
  end

  @[Vow::Export(skip: true)]             # keep a public method off the wire
  def diagnostics : String
    "..."
  end

  private def helper : Int32             # private/protected are never exported
    42
  end
end
```

The same typing rule applies — but now to _every_ public method, so opting a
class into `All` means committing to typed arguments and an explicit return type
across the board. Methods that aren't a plain identifier — operators (`+`,
`[]`), setters (`name=`), and predicate/bang methods (`valid?`, `save!`) — are
skipped automatically; add an explicit `@[Vow::Export(name: "...")]` to force one
onto the wire under a clean name. Either flavor mounts the same way (below).

#### Driving dispatch from your own annotation

If you're building a framework on top of Vow and already have your _own_ export
annotation, `include Vow::Exportable::Marked` and hand your marker to
`vow_register_marked` from one of your instance methods. Vow registers every
method carrying that annotation with the same decode → invoke → JSON-encode
callback it generates for `@[Vow::Export]` — reusing Vow's dispatch without
learning about your annotation:

```crystal
annotation Rpc; end

class ChatService
  include Vow::Exportable::Marked

  @[Rpc]
  def greet(name : String) : String
    "Hi, #{name}"
  end

  def install(registry : Vow::Registry) : Nil
    vow_register_marked(registry, Rpc)   # registers every @[Rpc] method
  end
end
```

Wire ids, camelCased arg keys, arg defaults, and a leading `Vow::Context`
parameter all behave exactly as under `@[Vow::Export]`. It's intentionally
narrower: it doesn't read the marker's options, so `name:`/`skip:`/opts are
yours to layer on top.

### 2. Call a method from Crystal

Build a registry from one or more service instances and dispatch by name:

```crystal
registry = Vow::Registry.new(API.new)
registry.dispatch("API.greet", %({"name": "world"}))   # => %("Hello, world!")
registry.dispatch("math.add", %({"a": 2, "b": 3}))     # => "5"
registry.dispatch("API.shout", %({"name": "sam"}))     # => %("Hey sam!"), excitement defaults
```

Arguments go in as a JSON object keyed by argument name; an optional arg can be
left out. The result comes back as a JSON string. This is the seam your
transport sits on.

### 3. Generate the client

`--out` is a stem; the target appends the extension(s):

```bash
vow gen --entry api.cr --target ts --out client   # → client.ts (one module)
vow gen --entry api.cr --target js --out client   # → client.js + client.d.ts
```

Vow compiles your file and runs it just far enough to read the exported methods
(before any of your own startup code runs), then writes the client. You don't
write a separate script to extract anything — pointing `--entry` at your source
is enough.

Use `ts` for a project with a bundler/TypeScript toolchain; use `js` for a
buildless browser (it runs the `.js` directly and reads the `.d.ts` for types).

### 4. Use the client

For the common case — HTTP to a mounted endpoint — the generated file ships a
batteries-included transport, so wiring up is one line:

```ts
import { createHttpClient } from "./client";

const api = createHttpClient("/rpc"); // done

await api.API.greet({ name: "world" }); // typed Promise<string>
```

`createHttpClient(url, options?)` builds each procedure's URL under `url` (a read
is a GET with args in `?input=`, a write is a POST with a JSON body), returns the
decoded result, and throws a typed [`VowError`](#errors) on the error envelope.
Need to send auth or other headers? Pass a `headers` _function_ — it's evaluated
per request, so a token that changes (or a reactive ref) is read fresh each call:

```ts
const api = createHttpClient("/rpc", {
  headers: () => ({ "X-User": user.value }),
});
```

**The escape hatch.** When you need a transport Vow doesn't ship — batching,
retries, websockets, auth refresh — the generated file also exports the lower-level
`createClient(transport)`. You supply the transport: the part that sends
`(name, args, opts)` to your backend and returns the result. `opts` is the
procedure's opaque opts bag (see [Opts](#opts-an-opaque-side-channel-for-transports))
— whatever you put on `@[Vow::Export]`, here for you to interpret. The default
`createHttpClient` is just this reading `opts.verb` (defaulting to `"post"`) to
pick GET vs POST, with a `fetch` wrapped in:

```ts
import { createClient, VowError } from "./client";

const api = createClient(async (name, args, opts) => {
  const verb = opts.verb ?? "post"; // your convention — Vow doesn't impose one
  const path = `/rpc/${name.replaceAll(".", "/")}`; // Users.find -> /rpc/Users/find
  const res = await fetch(
    verb === "get"
      ? `${path}?input=${encodeURIComponent(JSON.stringify(args))}`
      : path,
    verb === "get"
      ? { method: "GET" }
      : {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(args),
        },
  );
  const data = await res.json();
  if (!res.ok) throw new VowError(data.error, data.message, data.hint ?? null);
  return data;
});

await api.API.greet({ name: "world" }); // typed Promise<string>
```

Ready-made server-side transports live in their own shards: a registry is the
seam they mount, and the client is regenerated from its manifest.

## Errors

Vow raises a typed error across the dispatch boundary — a stable string `code`, a
`message`, and an optional `hint` — which a transport forwards as the wire
envelope `{ error, message, hint }`. The generated client mirrors this back as a
`VowError` class and a `VowErrorCode` union, so a `catch` is typed and the
built-in codes autocomplete:

```ts
import { VowError } from "./client";

try {
  await api.Todos.toggle({ id });
} catch (e) {
  if (e instanceof VowError) {
    e.code; // VowErrorCode: "not_found" | "bad_input" | "unauthorized" | "internal" | (string & {})
    e.hint; // string | null
  }
}
```

The four built-in codes come straight from Vow's `Vow::Error` constructors; the
union's open `(string & {})` arm keeps a downstream code your service or transport
mints (`rate_limited`, …) type-checking too. The default `createHttpClient`
transport throws `VowError` for you; a custom `createClient` transport throws it
itself (see the escape-hatch example above).

Dispatching an unknown procedure raises `not_found` — and if the name is a near
miss for a registered one, the error's `hint` suggests it, so a typo is
diagnosable rather than a dead end:

```crystal
registry.dispatch("API.gret", %({"name": "world"}))
# Vow::Error: no procedure named "API.gret" (not_found)
#   hint: did you mean "API.greet"?
```

The suggestion is the closest registered name within an edit-distance tolerance
that scales with the query length; a name that's wildly different gets no hint
rather than a misleading one.

## Custom types

If an exported method uses your own struct or class, include
[`JSON::Serializable`](https://crystal-lang.org/api/JSON/Serializable.html) in
it. Vow finds it automatically (including through arrays, unions, and nested
types) and generates a matching TypeScript `interface`:

```crystal
struct User
  include JSON::Serializable
  getter id : Int32
  getter name : String
  def initialize(@id, @name); end
end

class API
  include Vow::Exportable

  @[Vow::Export]
  def find(id : Int32) : User?
    # ...
  end
end
```

Field names follow what actually crosses the wire: a field renamed with
`@[JSON::Field(key: "displayName")]` appears in the interface as `displayName`,
and a field marked `@[JSON::Field(ignore: true)]` is left out entirely. The
interface never disagrees with the JSON.

If a referenced type can't be serialized, Vow stops with an error rather than
generating a client that wouldn't work.

An **enum** is captured the same way — found automatically wherever it's
referenced (directly, or through arrays, unions, `NamedTuple` members, and
struct fields) — and emitted as a string-literal union `type` alias rather than
an `interface`:

```crystal
enum Color
  Red
  Green
  Blue
end

@[Vow::Export]
def pick(name : String) : Color
  # ...
end
```

```ts
export type Color = "red" | "green" | "blue";
```

The union holds the value each member *serializes to* (`Enum#to_json`), so the
generated type always matches the wire: Crystal's default lowercases
(`Red` → `"red"`), and a custom `to_json` is reflected. Vow applies no transform
of its own.

## Naming

The generated client is idiomatic TypeScript: method names and argument keys are
camelCased (`def find_user(user_id : Int32)` becomes
`api.API.findUser({ userId })`). Namespace segments are your Crystal class and
module names, so they're left as written (`API`, not `api`). Custom type and
struct-field names follow the JSON exactly (see [Custom types](#custom-types)).

## CLI

```
vow gen      Generate a typed client from your methods
  -e, --entry    <app.cr>      your Crystal source file
  -m, --manifest <file.json>   a pre-generated manifest file, instead of --entry
  -o, --out      <stem>        output path stem; the target's extension is appended
  -t, --target   <ts|js>       ts → one .ts module; js → .js runtime + .d.ts types
  -c, --check                  verify --out is up to date; write nothing, exit ≠0 if it would change

vow version  Print the Vow version
```

A single-file target (`ts`) writes to stdout when `--out` is omitted (so you can
pipe it); status messages go to stderr. The `js` target emits two files, so it
needs `--out`.

If you commit the generated client, add `--check` to CI to guarantee it never
drifts from your services — it regenerates in memory and compares against the
files at `--out`, exiting non-zero (and naming what's stale) without writing:

```bash
vow gen --entry api.cr --target ts --out client --check
```

## Scope

A few things are deliberate, not missing:

- **No transport lock-in.** The generated client ships a default HTTP transport
  (`createHttpClient`) for the common case, but it's built on the framework-agnostic
  `createClient(transport)` seam — so anything else (batching, retries, websockets)
  is yours to supply, and Vow never binds you to a web server. Ready-made
  server-side bindings live downstream, in their own shards.
- **TypeScript / JavaScript client.** The frontend is written in
  TypeScript/JavaScript, so those are the targets: a `.ts` module, or a `.js`
  runtime plus a `.d.ts`.

A few signature shapes aren't supported yet. Rather than silently miscompile,
exporting one is a **compile-time error** naming the method, so you find out at
build time:

- **Splat args** (`*nums : Int32`) and **double splats** (`**opts : Int32`) —
  not yet representable over the named-args boundary. (A bare `*`, which only
  marks the following args as named-only, _is_ supported.)
- **Block parameters** (`&blk`) — a block can't cross a JSON boundary.
- **Default values that reference an earlier parameter** (`def f(a, b = a)`) —
  the default is materialized in generated code where the earlier parameter
  isn't in scope; use a literal default instead.

## Development

```bash
crystal spec      # run the tests
```

Vow uses [argy](https://github.com/AristoRap/argy) for its CLI. If
`shards install` fails with a `safe.bareRepository` error, your global git has
`safe.bareRepository = explicit`; run the command with this prefix:

```bash
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all shards install
```

## License

MIT
