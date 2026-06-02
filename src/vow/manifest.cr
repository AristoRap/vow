require "json"

module Vow
  # One exported argument: its name, its declared Crystal type (captured
  # verbatim from the signature — `"Int32"`, `"Array(String)"`, …), and whether
  # it's optional (has a default value, so the caller may omit it). The type
  # string is the raw Crystal type — mapping it to a target language
  # (TypeScript, …) happens in the codegen layer, not here, so the manifest
  # stays a pure, target-agnostic structural IR that can't misrepresent the
  # signature. `optional` defaults to `false` so manifests written before this
  # field existed still deserialize.
  struct ArgDescriptor
    include JSON::Serializable
    getter name : String
    getter type : String
    getter optional : Bool = false

    def initialize(@name : String, @type : String, @optional : Bool = false)
    end
  end

  # The static description of one `@[Vow::Export]` method: the dispatch id, its
  # args, its return type, and an opaque bag of `opts`. Produced at compile time
  # by `Vow::Exportable` and readable WITHOUT instantiating the service
  # (`MyService.vow_descriptors`), so a code generator never has to construct or
  # run user code.
  #
  # `opts` is every `@[Vow::Export]` keyword argument except the reserved `name:`
  # and `skip:`, carried through VERBATIM. Vow validates nothing about it and
  # attaches no meaning to any key — it is a side channel for whatever a
  # downstream transport cares about (`verb:` for HTTP routing, a cache TTL, an
  # auth scope, …). Each value keeps its literal type (`:get` → the string
  # `"get"`, `30` → the number `30`, `true` → the boolean `true`), so a transport
  # reads it back as the type it was written as. A transport that knows none of
  # these keys ignores the whole bag — Vow itself never sets a header, builds a
  # URL, or branches on a value here. It defaults to empty so manifests written
  # before this field existed (and ones whose methods carry no opts) deserialize
  # cleanly.
  struct ProcedureDescriptor
    include JSON::Serializable
    getter name : String
    getter args : Array(ArgDescriptor)
    # The Crystal getter stays snake_case; the wire key is camelCase because the
    # manifest is consumed in JS/TS where `returnType` is the convention.
    @[JSON::Field(key: "returnType")]
    getter return_type : String
    getter opts : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(@name : String, @args : Array(ArgDescriptor), @return_type : String, @opts : Hash(String, JSON::Any) = {} of String => JSON::Any)
    end
  end

  # One field of a captured surface type: its name and raw Crystal type string.
  struct FieldDescriptor
    include JSON::Serializable
    getter name : String
    getter type : String

    def initialize(@name : String, @type : String)
    end
  end

  # A custom type that crosses the boundary — captured automatically when an
  # `@[Vow::Export]` signature references a `JSON::Serializable` struct/class
  # (transitively, through generics and unions) or an `Enum`. `crystal_name` is
  # the full Crystal path (used to match references and dedup); `name` is the
  # simple name a codegen target emits.
  #
  # `kind` distinguishes the two captured shapes a target renders differently:
  # `"struct"` (the default — a record emitted as a TS `interface` from
  # `fields`) and `"enum"` (emitted as a string-literal-union `type` alias from
  # `members` — the member names captured verbatim, with no case/format
  # transform). `kind`/`members` default so manifests written before they
  # existed still deserialize. A non-serializable, non-enum custom type is
  # rejected at compile time, so anything captured here is guaranteed to cross.
  struct TypeDescriptor
    include JSON::Serializable
    getter name : String
    # Snake_case getter, camelCase wire key — see `ProcedureDescriptor#return_type`.
    @[JSON::Field(key: "crystalName")]
    getter crystal_name : String
    getter fields : Array(FieldDescriptor)
    getter kind : String = "struct"
    getter members : Array(String) = [] of String

    def initialize(
      @name : String,
      @crystal_name : String,
      @fields : Array(FieldDescriptor),
      @kind : String = "struct",
      @members : Array(String) = [] of String,
    )
    end
  end

  # The full set of procedures (and the custom types they reference) a build
  # exposes — the contract a codegen target or transport consumes. Serializes
  # to `{"procedures": [...], "types": [...]}` so it can be dumped to disk or
  # piped to an out-of-process generator.
  struct Manifest
    include JSON::Serializable
    getter procedures : Array(ProcedureDescriptor)
    getter types : Array(TypeDescriptor)

    def initialize(
      @procedures : Array(ProcedureDescriptor) = [] of ProcedureDescriptor,
      @types : Array(TypeDescriptor) = [] of TypeDescriptor,
    )
    end
  end
end
