module Vow
  # Optional per-call request context. An exported method opts in by declaring
  # a *leading* parameter typed `Vow::Context` (or a transport's subclass); the
  # macro then threads the context the transport passed to `Registry#dispatch`
  # into that argument and leaves it out of the JSON-decoded args, the manifest,
  # and the generated client signature. A method that declares no such parameter
  # is unaffected — context is purely opt-in.
  #
  # This base carries nothing transport-specific. A transport subclasses it with
  # real accessors (headers, remote IP, …); the generic `[]` lets a service read
  # string metadata without naming a concrete transport type.
  abstract class Context
    # Look up a string-valued piece of request metadata (e.g. a header) by key,
    # or `nil` if absent. Transports decide what keys mean.
    abstract def [](key : String) : String?
  end
end
