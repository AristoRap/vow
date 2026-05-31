module Vow
  # Root of every error Vow raises across the dispatch boundary. Carries a
  # stable string `code` (what a transport forwards to its client) plus an
  # optional `hint`. The code is a string rather than an enum so downstream
  # transports and services can mint their own (`sqlite_not_open`,
  # `rate_limited`, …) without editing Vow. The convenience constructors below
  # cover Vow's built-in categories; `Vow::Error.new("my_code", msg)` covers the
  # rest.
  class Error < Exception
    # Vow's built-in error codes, in definition order. The single source of
    # truth shared by the convenience constructors below and the codegen, which
    # emits them as the `VowErrorCode` union so the generated client's `catch`
    # autocompletes the same codes Vow actually raises. Downstream codes stay
    # representable through the union's open `(string & {})` arm — listing the
    # built-ins here doesn't close it.
    BUILTIN_CODES = %w[bad_input not_found unauthorized internal]

    getter code : String
    getter hint : String?

    def initialize(@code : String, message : String, @hint : String? = nil)
      super(message)
    end

    # Caller sent something Vow couldn't accept: malformed JSON, wrong arg
    # count, or an arg that wouldn't decode into its declared type.
    def self.bad_input(message : String, hint : String? = nil) : Error
      new("bad_input", message, hint)
    end

    # Dispatch was asked for a procedure name that isn't registered.
    def self.not_found(message : String, hint : String? = nil) : Error
      new("not_found", message, hint)
    end

    def self.unauthorized(message : String, hint : String? = nil) : Error
      new("unauthorized", message, hint)
    end

    def self.internal(message : String, hint : String? = nil) : Error
      new("internal", message, hint)
    end
  end
end
