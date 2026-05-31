require "json"
require "./context"

module Vow
  # A single dispatchable unit: a name plus a callback that takes the call's
  # named args (a `Hash` of arg name => raw `JSON::Any`) and the optional
  # per-call `Context`, and returns a `JSON::Any` result.
  #
  # The callback is what the `Vow::Exportable` macro generates per exported
  # method — it owns required-arg checking, per-arg typed decoding (by name,
  # honoring defaults), the real method call, and result encoding. Methods that
  # don't opt into context simply ignore the second argument. Keeping
  # `Procedure` this thin (just name + proc) is deliberate: all the *static*
  # metadata a code generator wants (arg names, types, return type) lives in the
  # separate Manifest layer, so codegen never has to instantiate a service.
  struct Procedure
    getter name : String
    getter callback : Proc(Hash(String, JSON::Any), Context?, JSON::Any)

    def initialize(@name : String, @callback : Proc(Hash(String, JSON::Any), Context?, JSON::Any))
    end
  end
end
