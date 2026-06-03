# Changelog

## [0.5.0] - 2026-06-03

### Changed

- **The bundled `createHttpClient` no longer names any opt key — you supply the GET/POST rule** _(breaking)_. 0.4.0 made `verb` an ordinary opt but left the bundled client still reading `opts.verb`, so Vow was effectively choosing the key. Now the client is fully agnostic: `HttpClientOptions` gains `method?: (opts) => "GET" | "POST"`, a function _you_ pass that maps a procedure's opts bag to a verb. The client reads no opt itself.
  - **Default behavior changed:** with no `method`, **every call is a POST**. Previously a `verb: "get"` opt was routed to GET automatically. To restore that, pass `method: (opts) => opts.verb === "get" ? "GET" : "POST"` (or key it on whatever opt you chose — `read`, `cache`, anything).
  - The escape-hatch `createClient(transport)` is unchanged; opts still flow to your transport verbatim. Only the bundled HTTP client's signature and default differ.

## [0.4.0] - 2026-06-02

### Changed

- **`verb` is gone as a privileged field; it's now just one entry in an opaque `opts` bag** _(breaking)_. Vow is transport-agnostic, but `verb` baked an HTTP concept into the core: the macro hard-rejected anything but `:get`/`:post`, and the word leaked into the generated transport signature. Now **any `@[Vow::Export]` keyword except the reserved `name:`/`skip:`** is swept into `opts` and carried into the manifest and the generated client **verbatim** — Vow validates nothing and attaches no meaning to any key. Each value keeps its literal type (`:get` → `"get"`, `30` → `30`, `true` → `true`). The bundled `createHttpClient` reads `opts.verb` to route GET vs POST, because that's an HTTP transport's job, not Vow's. _(Superseded in 0.5.0: the bundled client no longer names `verb` — you supply a `method` rule.)_
  - `ProcedureDescriptor#verb : String` is replaced by `#opts : Hash(String, JSON::Any)` (wire key `"opts"`, defaults to empty).
  - The generated transport signature changes from `(name, args, verb)` to `(name, args, opts)`; bring-your-own transports passed to `createClient` must update accordingly.
  - A manifest written by 0.3.x carried a top-level `verb` key and no `opts`; it still deserializes (the unknown `verb` key is ignored, `opts` defaults empty), but a `verb: "get"` is **lost** — regenerate the manifest from source to restore GET routing.
  - `@[Vow::Export(verb: :anything)]` now compiles: Vow no longer validates the value. A transport that cares (e.g. an HTTP one) validates its own opts.

## [0.3.0]

### Changed

- **Manifest JSON keys are camelCase** _(breaking)_. The manifest is consumed in JS/TS, so its multi-word keys now match that convention: `return_type` → `returnType` (on `ProcedureDescriptor`) and `crystal_name` → `crystalName` (on `TypeDescriptor`). The Crystal getters keep their snake_case names; only the wire/serialized form changed (via `@[JSON::Field(key: ...)]`). A pre-generated manifest file written by 0.2.x must be regenerated, and any consumer reading the raw manifest JSON by key must use the new names.

## [0.2.0] - 2026-06-01

### Added

- **`Vow::Exportable::Marked` — consumer-driven dispatch registration.** A downstream framework with its _own_ export annotation can `include Vow::Exportable::Marked` and call `vow_register_marked(registry, MyAnnotation)` from one of its instance methods. Because the macro expands in the consumer's class context, Vow registers every method carrying that annotation with the exact decode → invoke → JSON-encode callback it generates for `@[Vow::Export]` — so the consumer reuses Vow's dispatch instead of reimplementing it, while keeping its own annotation and ids. Vow stays annotation-agnostic (the marker is the consumer's type, matched via `m.annotation(marker.resolve)`).
- **"Did you mean?" suggestions on unknown dispatch.** `Registry#dispatch` now attaches a `hint` to the `not_found` error naming the closest registered procedure (nearest edit distance within a length-scaled tolerance, via stdlib `Levenshtein`), or no hint when nothing is close. A transport that surfaces `Vow::Error#hint` turns a typo'd procedure name into an actionable message.
- **Enum capture → TypeScript string-literal union.** An `Enum` referenced by an exported signature (directly or transitively, through generics/unions/`NamedTuple` members/struct fields) is now captured as a `TypeDescriptor` with `kind: "enum"` and its serialized values, and emitted as a `type X = "a" | "b" | "c";` alias instead of being rejected at the boundary. The union records the value each member **serializes to** (`Enum#to_json`), so the generated type always matches the wire: Crystal's default lowercases (`Red` → `"red"`), and a custom `to_json` is reflected. Vow applies no transform of its own. `TypeDescriptor` gains `kind` (`"struct"` default) and `members`, both defaulted so older manifests still deserialize.

## [0.1.1] - 2026-06-01

### Fixed

- `Vow::Codegen.collect` no longer crashes the compiler (stack overflow from infinite macro recursion) when an exported signature returns or accepts a `NamedTuple`. NamedTuples are now walked by key: nested `JSON::Serializable` members are captured as surface types, while the NamedTuple itself stays an inline `{ ... }` shape via `crystal_to_ts`.

## [0.1.0]

- Initial release: typed RPC codegen — a TypeScript/JavaScript client generated from annotated Crystal methods, with a transport-agnostic `Vow::Registry#dispatch` seam.
