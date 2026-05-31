require "json"
require "argy"
require "../vow"

module Vow
  module CLI
    # `vow gen` — turn a Vow manifest into a typed client.
    #
    # Two ways to supply the manifest:
    #   --manifest <file.json>  read a manifest JSON file directly (pure, no compile)
    #   --entry    <app.cr>     compile+run a Crystal file that requires Vow and
    #                           annotates methods with @[Vow::Export]; Vow emits
    #                           the manifest itself — no dump code to write
    #
    # With --check, nothing is written: Vow regenerates in memory and compares
    # against the files already at --out, exiting non-zero if they differ. Commit
    # the generated client, then run `vow gen … --out client --check` in CI to fail
    # the build when a service change left the checked-in client stale.
    module Gen
      def self.command : Argy::Command
        cmd = Argy::Command.new(use: "gen", short: "Generate a typed client from a Vow manifest")
        cmd.flags.string("manifest", 'm', "", "path to a manifest JSON file")
        cmd.flags.string("entry", 'e', "", "path to a Crystal entry that emits a manifest")
        cmd.flags.string("out", 'o', "", "output path stem; the target's extension is appended (defaults to stdout)")
        cmd.flags.string("target", 't', "ts", "client target: ts (single .ts module) or js (.js runtime + .d.ts)")
        cmd.flags.bool("check", 'c', false, "verify the client at --out is up to date; write nothing, exit non-zero if it would change")
        cmd.on_run { |c, _args| run(c) }
        cmd
      end

      # Writes through the command's `stdout`/`stderr` (argy 0.4+) rather than
      # the global streams: the generated client goes to `stdout`, the
      # "wrote …" status to `stderr`, so callers (and specs) can redirect or
      # capture output instead of polluting the real terminal.
      def self.run(cmd : Argy::Command) : Nil
        manifest = ::Vow::Manifest.from_json(load_manifest_json(cmd))
        target = cmd.string_flag("target")
        artifacts = emit(target, manifest)

        dest = cmd.string_flag("out")
        if cmd.bool_flag("check")
          # Verify-only: regenerate in memory and diff against what's on disk,
          # writing nothing. There must be files to compare, so --out is required.
          abort "vow: --check needs --out <path> (the client files to verify)" if dest.empty?
          verify(cmd, manifest, artifacts, dest)
        elsif dest.empty?
          # A single-file target pipes to stdout; a multi-file one (js → .js +
          # .d.ts) can't, so it requires --out rather than concatenating files
          # that aren't valid back to back.
          if artifacts.size == 1
            cmd.stdout.puts artifacts.first[:content]
          else
            abort "vow: --target #{target} emits #{artifacts.size} files (.js + .d.ts); pass --out <path> (e.g. public/vowClient) so they're written side by side"
          end
        else
          paths = artifacts.map { |a| out_path(dest, a[:role]) }
          artifacts.each_with_index { |a, i| File.write(paths[i], a[:content]) }
          cmd.stderr.puts "vow: wrote #{manifest.procedures.size} procedure(s), #{manifest.types.size} type(s) → #{paths.join(", ")}"
        end
      rescue ex : ::Vow::Error
        # Fail loud and actionable — never emit a half/guessed client.
        abort "vow: #{ex.message}"
      rescue ex : JSON::ParseException
        abort "vow: manifest is not valid JSON — #{ex.message}"
      end

      # Compares each freshly emitted artifact against the file already at its
      # --out path, writing nothing. Prints a status line to `stderr` and returns
      # when every file is current; aborts non-zero, naming what drifted, when any
      # file differs or is missing — so a CI step can gate on the checked-in client
      # matching the services. A missing file counts as stale (it would be written).
      private def self.verify(cmd : Argy::Command, manifest : ::Vow::Manifest, artifacts : Array(NamedTuple(role: String, content: String)), dest : String) : Nil
        paths = artifacts.map { |a| out_path(dest, a[:role]) }
        stale = [] of String
        artifacts.each_with_index do |a, i|
          current = File.exists?(paths[i]) && File.read(paths[i]) == a[:content]
          stale << paths[i] unless current
        end

        if stale.empty?
          cmd.stderr.puts "vow: client is up to date (#{manifest.procedures.size} procedure(s), #{manifest.types.size} type(s)) → #{paths.join(", ")}"
        else
          abort "vow: client is out of date — regenerate without --check to update. Stale: #{stale.join(", ")}"
        end
      end

      # An ordered list of files a target produces. `ts` is one `.ts` module;
      # `js` is the runtime `.js` plus its companion `.d.ts` (types the editor
      # reads beside the runtime), so a buildless browser import is fully typed.
      private def self.emit(target : String, manifest : ::Vow::Manifest) : Array(NamedTuple(role: String, content: String))
        case target
        when "ts", "typescript"
          [{role: "ts", content: ::Vow::Codegen::TypeScript.emit(manifest)}]
        when "js", "javascript"
          [{role: "js", content: ::Vow::Codegen::JavaScript.emit(manifest)},
           {role: "dts", content: ::Vow::Codegen::TypeScript.emit_dts(manifest)}]
        else
          abort "vow: unknown target #{target.inspect} (supported: ts, js)"
        end
      end

      # The extension for each artifact role. `--target` already names the
      # language, so `--out` is a stem (`public/vowClient`), not a filename with
      # an extension to repeat — Vow appends the right one(s): `.ts` for the
      # `ts` module, `.js` + `.d.ts` for the `js` runtime and its types.
      ROLE_EXT = {"ts" => ".ts", "js" => ".js", "dts" => ".d.ts"}

      # A trailing client extension on `--out` is tolerated (and stripped) so an
      # explicit `--out client.js` still does the sensible thing; longest first
      # so `.d.ts` isn't mistaken for `.ts`.
      STEM_EXTS = [".d.ts", ".mjs", ".js", ".ts"]

      private def self.out_path(dest : String, role : String) : String
        stem = dest
        if ext = STEM_EXTS.find { |e| dest.ends_with?(e) }
          stem = dest[0...-ext.size]
        end
        stem + ROLE_EXT[role]
      end

      private def self.load_manifest_json(cmd : Argy::Command) : String
        manifest = cmd.string_flag("manifest")
        entry = cmd.string_flag("entry")

        if !manifest.empty? && !entry.empty?
          abort "vow: pass either --manifest or --entry, not both"
        elsif !manifest.empty?
          File.exists?(manifest) || abort("vow: manifest file not found: #{manifest}")
          File.read(manifest)
        elsif !entry.empty?
          run_entry(entry)
        else
          abort "vow: provide --manifest <file.json> or --entry <app.cr>"
        end
      end

      # Compiles and runs the entry with `--vow-emit-manifest`, then extracts the
      # framed manifest from its stdout. Vow's auto-emit hook does the printing,
      # so the entry needs nothing but the annotations. Framing means startup
      # noise still works; a file with no exports fails loud (nonzero exit) and
      # surfaces here as a compile/run failure rather than a cryptic parse error.
      private def self.run_entry(entry : String) : String
        File.exists?(entry) || abort("vow: entry file not found: #{entry}")
        stdout = IO::Memory.new
        stderr = IO::Memory.new
        status = Process.run("crystal", ["run", "--no-color", entry, "--", ::Vow::MANIFEST_FLAG], output: stdout, error: stderr)
        abort("vow: entry failed to compile/run (#{entry}):\n#{stderr}") unless status.success?
        extract_manifest(stdout.to_s, entry)
      end

      private def self.extract_manifest(output : String, entry : String) : String
        b = output.index(::Vow::MANIFEST_BEGIN)
        e = output.index(::Vow::MANIFEST_END)
        unless b && e && e > b
          abort <<-MSG
            vow: `#{entry}` ran but produced no manifest.
                 An --entry must `require` Vow and define at least one exported
                 method — annotate with @[Vow::Export] inside an
                 `include Vow::Exportable` class (or `include Vow::Exportable::All`
                 to export every public method):

                   require "vow"

                   class API
                     include Vow::Exportable

                     @[Vow::Export]
                     def greet(name : String) : String
                       "Hello, #{name}!"
                     end
                   end

                 (To generate from an existing manifest file instead, use: vow gen --manifest <file.json>)
            MSG
        end
        output[(b + ::Vow::MANIFEST_BEGIN.size)...e].strip
      end
    end
  end
end
