require "json"
require "./error"
require "./procedure"
require "./manifest"

module Vow
  # Holds the set of dispatchable procedures and turns a `(name, raw JSON)`
  # pair into a `raw JSON` result. This is Vow's transport-agnostic seam: an
  # HTTP adapter, a CLI, or a test harness all sit on `dispatch` and never
  # touch how a procedure was generated.
  #
  # Mount one or more services to populate it — `Vow::Registry.new(api, other)`
  # or `registry.mount(api)`. Mounting binds each service instance's exported
  # methods (the generated callbacks close over that instance) and records its
  # static descriptors, so the registry can also answer `#manifest` for codegen
  # and introspection.
  class Registry
    def initialize
      @procedures = {} of String => Procedure
      @descriptors = [] of ProcedureDescriptor
      @types = [] of TypeDescriptor
    end

    def initialize(*services : ::Vow::Mountable)
      initialize
      services.each { |service| mount(service) }
    end

    # Bind a service instance into this registry. Returns self for chaining.
    # Accepts anything `Vow::Mountable` — a class that mixed in either
    # `Vow::Exportable` or `Vow::Exportable::All`.
    def mount(service : ::Vow::Mountable) : self
      service.vow_install(self)
      self
    end

    def register(name : String, &callback : Hash(String, JSON::Any), Context? -> JSON::Any) : Nil
      @procedures[name] = Procedure.new(name, callback)
    end

    # Called by the generated `vow_install` to record a service's static
    # descriptors alongside its runtime callbacks.
    def add_descriptors(descriptors : Array(ProcedureDescriptor)) : Nil
      @descriptors.concat(descriptors)
    end

    # Records a service's captured surface types. Deduped at `#manifest` time
    # so types shared across mounted services appear once.
    def add_types(types : Array(TypeDescriptor)) : Nil
      @types.concat(types)
    end

    # The static contract of everything mounted here — for codegen, an
    # introspection endpoint, or a health check.
    def manifest : Manifest
      seen = Set(String).new
      Manifest.new(@descriptors, @types.select { |t| seen.add?(t.crystal_name) })
    end

    # Names of every registered procedure, in insertion order — handy for
    # introspection, health checks, and "did you mean?" diagnostics.
    def names : Array(String)
      @procedures.keys
    end

    def includes?(name : String) : Bool
      @procedures.has_key?(name)
    end

    # The seam transports sit on: procedure name + raw JSON args object in,
    # raw JSON result out. Typed `Vow::Error`s (not-found, bad-input, decode
    # failures) propagate to the caller, which is responsible for turning them
    # into a transport-appropriate envelope.
    #
    # *context* is the optional per-call `Context` a transport supplies; it
    # reaches only the methods that opt in by declaring a leading `Context`
    # parameter. Defaulting to `nil` keeps the bare `dispatch(name, args)` call
    # — used by context-free transports and tests — working unchanged.
    def dispatch(name : String, raw_json : String, context : Context? = nil) : String
      proc = @procedures[name]?
      raise Error.not_found("no procedure named #{name.inspect}") unless proc
      proc.callback.call(parse_args(raw_json), context).to_json
    end

    # Trust boundary: decode one positional arg into its declared type, turning
    # any parse/shape failure into a typed `bad_input` instead of a raw crash.
    # Called once per arg by the generated callbacks.
    def self.decode(type : T.class, arg : JSON::Any) : T forall T
      T.from_json(arg.to_json)
    rescue ex : JSON::ParseException | JSON::SerializableError
      raise Error.bad_input("could not decode arg as #{T}: #{ex.message}")
    end

    # Args arrive as a JSON object keyed by argument name. Decoding into each
    # declared type, checking required args, and applying defaults all happen in
    # the generated callback — here we only assert the payload is an object.
    private def parse_args(raw_json : String) : Hash(String, JSON::Any)
      obj = JSON.parse(raw_json).as_h?
      raise Error.bad_input("expected JSON object of named args, got #{raw_json.inspect}") unless obj
      obj
    rescue ex : JSON::ParseException
      raise Error.bad_input("invalid JSON: #{ex.message}")
    end
  end
end
