require "json"
require "./vow/error"
require "./vow/context"
require "./vow/procedure"
require "./vow/manifest"
require "./vow/registry"
require "./vow/mountable"
require "./vow/exportable"
require "./vow/codegen/type_map"
require "./vow/codegen/tree"
require "./vow/codegen/typescript"
require "./vow/codegen/javascript"

# Vow — annotate your methods, Vow generates the dispatch glue.
#
# Annotate instance methods with `@[Vow::Export]`, `include Vow::Exportable`
# (or `include Vow::Exportable::All` to export every public method), and the
# compiler generates an `install(registry)` that registers each as a typed,
# JSON-in/JSON-out procedure. Transports (HTTP, CLI, …) sit on
# `Vow::Registry#dispatch` and stay out of the codegen.
#
#   class API
#     include Vow::Exportable
#
#     @[Vow::Export]
#     def greet(name : String) : String
#       "Hello, #{name}!"
#     end
#   end
#
#   registry = Vow::Registry.new(API.new)
#   registry.dispatch("API.greet", %(["world"])) # => %("Hello, world!")
module Vow
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify }}

  # Markers framing the manifest JSON on stdout, so `vow gen --entry` can lift
  # it out cleanly even if the program writes other things at startup.
  MANIFEST_BEGIN = "<<<VOW_MANIFEST"
  MANIFEST_END   = "VOW_MANIFEST>>>"

  # The flag that turns any Vow program into a manifest emitter. `vow gen
  # --entry` compiles the user's annotated program and runs it with this — the
  # user writes no dump code; the `@[Vow::Export]` annotations are the input.
  MANIFEST_FLAG = "--vow-emit-manifest"

  # The manifest for EVERY Vow service in the compiled program, built at the
  # end of compilation straight from the statically-captured descriptors — no
  # instances, no registry, no user code. Both mixins route through
  # `Vow::Exportable::Generated`, so its includers are exactly the services to
  # gather (annotated or export-all alike).
  macro finished
    def self.discovered_manifest : Manifest
      descriptors = [] of ProcedureDescriptor
      types = [] of TypeDescriptor
      {% for service in Vow::Exportable::Generated.includers %}
        {% unless service.abstract? %}
          descriptors.concat({{ service }}.vow_descriptors)
          types.concat({{ service }}.vow_types)
        {% end %}
      {% end %}
      seen = Set(String).new
      Manifest.new(descriptors, types.select { |t| seen.add?(t.crystal_name) })
    end
  end

  # Writes the discovered manifest to `io`, framed by the markers. Raises
  # `Vow::Error` when nothing is annotated — Vow never emits an empty client.
  # Pure and testable: no `exit`, no ARGV.
  def self.emit_manifest(io : IO = STDOUT) : Nil
    manifest = discovered_manifest
    if manifest.procedures.empty?
      raise Error.internal(
        "no exported methods found — `include Vow::Exportable` and annotate methods with @[Vow::Export], " +
        "or `include Vow::Exportable::All` to export every public method"
      )
    end
    io << MANIFEST_BEGIN << '\n'
    io << manifest.to_json << '\n'
    io << MANIFEST_END << '\n'
  end

  # Auto-installed below: under `--vow-emit-manifest`, emit the manifest and
  # exit before any user code runs; otherwise do nothing. A thin `exit` wrapper
  # around `emit_manifest`, kept separate so the emit logic stays testable.
  def self.maybe_emit_manifest(argv : Array(String) = ARGV) : Nil
    return unless argv.includes?(MANIFEST_FLAG)
    emit_manifest(STDOUT)
    STDOUT.flush
    exit 0
  rescue ex : Error
    STDERR.puts "vow: #{ex.message}"
    exit 1
  end
end

# Zero-boilerplate manifest emission: any program that requires Vow becomes a
# manifest source under `--vow-emit-manifest`. This runs before user code (Vow
# is required first), so it short-circuits ahead of side effects like booting a
# server — and does nothing at all without the flag.
Vow.maybe_emit_manifest
