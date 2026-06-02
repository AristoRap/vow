require "../manifest"
require "../error"
require "./type_map"
require "./tree"

module Vow
  module Codegen
    # Emits TypeScript from a `Vow::Manifest`:
    #
    #   * `emit`     — a `.ts` module: `VowTransport` type, the `VowError`
    #                  class + `VowErrorCode` union, an `interface` per captured
    #                  type, a `createClient(transport)` *function* (typed
    #                  implementation), and a batteries-included
    #                  `createHttpClient(url, options?)` factory. For TS projects
    #                  with a bundler.
    #   * `emit_dts` — a `.d.ts` declaration: the same types and `declare`d
    #                  `createClient` / `createHttpClient` signatures with no
    #                  bodies. Pairs with the JavaScript runtime so a buildless
    #                  consumer still gets full autocomplete (the editor reads
    #                  the `.d.ts` beside the `.js`).
    #
    # `createClient(transport)` is the escape hatch — bring your own transport
    # (batching, retries, websockets, auth refresh). `createHttpClient` is the
    # zero-config default for the 95% case: POST JSON to a URL, throw a typed
    # `VowError` on the error envelope. It's built *on* `createClient`, so the
    # seam stays the same.
    #
    # Pure functions of the manifest: no filesystem, no instances. Every type
    # maps via `crystal_to_ts`, which raises rather than emit `any`.
    module TypeScript
      TRANSPORT = "export type VowTransport = (name: string, args: Record<string, unknown>, opts: Record<string, unknown>) => Promise<unknown>;\n"

      # The typed error a generated client throws. `code` is the stable
      # `VowErrorCode`; `hint` mirrors the server's optional hint. Pairs with the
      # error envelope (`{ error, message, hint }`) the default transport reads.
      VOW_ERROR = <<-TS
        export class VowError extends Error {
          readonly code: VowErrorCode;
          readonly hint: string | null;
          constructor(code: VowErrorCode, message: string, hint: string | null = null) {
            super(message);
            this.name = "VowError";
            this.code = code;
            this.hint = hint;
          }
        }
        TS

      # The `.d.ts` form of `VowError`: the shape, no implementation.
      VOW_ERROR_DTS = <<-TS
        export declare class VowError extends Error {
          readonly code: VowErrorCode;
          readonly hint: string | null;
          constructor(code: VowErrorCode, message: string, hint?: string | null);
        }
        TS

      # Options for `createHttpClient`. `headers` is a *function*, evaluated per
      # request — so a token that changes (or a reactive ref) is read fresh each
      # call, rather than captured once. Shared verbatim by `.ts` and `.d.ts`.
      HTTP_OPTIONS = <<-TS
        export interface HttpClientOptions {
          headers?: () => Record<string, string>;
        }
        TS

      # The batteries-included default transport, built on `createClient`. Each
      # procedure has its own URL — *url* is the mount base, the dotted procedure
      # id becomes the path (`Todos.list` → `<url>/Todos/list`). This is the one
      # place that reads an opt: a `verb` of `"get"` (defaulting to `"post"` when
      # absent) marks a side-effect-free read, sent as GET with its args
      # JSON-encoded in `?input=` (so a browser/CDN can cache it); everything else
      # is POSTed with a JSON body. Knowing what `verb` means is this HTTP
      # transport's business, not Vow's. Returns the decoded result, or throws a
      # typed `VowError` from the `{ error, message, hint }` envelope on a non-2xx
      # response.
      HTTP_CLIENT = <<-TS
        export function createHttpClient(url: string, options: HttpClientOptions = {}) {
          return createClient(async (name, args, opts) => {
            const path = `${url}/${name.replaceAll(".", "/")}`;
            const verb = (opts.verb as string) ?? "post";
            const res = verb === "get"
              ? await fetch(
                  Object.keys(args).length
                    ? `${path}?input=${encodeURIComponent(JSON.stringify(args))}`
                    : path,
                  { method: "GET", headers: { ...(options.headers?.() ?? {}) } },
                )
              : await fetch(path, {
                  method: "POST",
                  headers: { "Content-Type": "application/json", ...(options.headers?.() ?? {}) },
                  body: JSON.stringify(args),
                });
            const data = await res.json();
            if (!res.ok) throw new VowError(data.error, data.message, data.hint ?? null);
            return data;
          });
        }
        TS

      def self.emit(manifest : Manifest) : String
        known = known_types(manifest)
        leaf = ->(seg : String, p : ProcedureDescriptor) do
          ret = Codegen.return_to_ts(p.return_type, known)
          "#{signature(seg, p, known, declaration: false)} { return transport(#{p.name.inspect}, args, #{Codegen.opts_literal(p.opts)}) as Promise<#{ret}>; }"
        end
        body = Codegen.render_tree(Codegen.build_tree(manifest.procedures), 2, type_mode: false, leaf: leaf)

        String.build do |s|
          s << "// Generated by Vow — do not edit by hand.\n\n"
          s << TRANSPORT
          s << "\n" << error_code_union
          s << "\n" << VOW_ERROR << "\n"
          emit_interfaces(s, manifest, known)
          s << "\nexport function createClient(transport: VowTransport) {\n"
          s << "  return " << body << ";\n"
          s << "}\n"
          s << "\n" << HTTP_OPTIONS << "\n"
          s << "\n" << HTTP_CLIENT << "\n"
        end
      end

      def self.emit_dts(manifest : Manifest) : String
        known = known_types(manifest)
        leaf = ->(seg : String, p : ProcedureDescriptor) { signature(seg, p, known, declaration: true) }
        shape = Codegen.render_tree(Codegen.build_tree(manifest.procedures), 0, type_mode: true, leaf: leaf)

        String.build do |s|
          s << "// Generated by Vow — do not edit by hand.\n\n"
          s << TRANSPORT
          s << "\n" << error_code_union
          s << "\n" << VOW_ERROR_DTS << "\n"
          emit_interfaces(s, manifest, known)
          s << "\nexport declare function createClient(transport: VowTransport): " << shape << ";\n"
          s << "\n" << HTTP_OPTIONS << "\n"
          s << "\nexport declare function createHttpClient(url: string, options?: HttpClientOptions): " << shape << ";\n"
        end
      end

      # The `VowErrorCode` union — Vow's built-in codes from a single source
      # (`Vow::Error::BUILTIN_CODES`) plus an open `(string & {})` arm so a
      # downstream code still type-checks while the built-ins autocomplete.
      private def self.error_code_union : String
        arms = ::Vow::Error::BUILTIN_CODES.map(&.inspect)
        "export type VowErrorCode = #{arms.join(" | ")} | (string & {});\n"
      end

      private def self.known_types(manifest : Manifest) : Hash(String, String)
        known = {} of String => String
        dedup_types(manifest.types).each { |t| known[t.crystal_name] = t.name }
        known
      end

      private def self.emit_interfaces(s : IO, manifest : Manifest, known : Hash(String, String)) : Nil
        interfaces = dedup_types(manifest.types).map { |t| render_interface(t, known) }
        s << "\n" << interfaces.join("\n\n") << "\n" unless interfaces.empty?
      end

      private def self.dedup_types(types : Array(TypeDescriptor)) : Array(TypeDescriptor)
        seen = Set(String).new
        types.select { |t| seen.add?(t.crystal_name) }
      end

      # A struct renders as an `interface` of its fields; an enum renders as a
      # `type` alias to the string-literal union of its member names (verbatim).
      private def self.render_interface(type : TypeDescriptor, known : Hash(String, String)) : String
        if type.kind == "enum"
          return "export type #{type.name} = #{type.members.map(&.inspect).join(" | ")};"
        end
        body = type.fields.map { |f| "  #{ts_member(f.name)}: #{Codegen.crystal_to_ts(f.type, known)};" }.join("\n")
        "export interface #{type.name} {\n#{body}\n}"
      end

      # A JSON key that isn't a valid JS identifier (e.g. `"first-name"`) is
      # emitted quoted, so the interface matches the wire key exactly rather
      # than silently producing invalid TypeScript.
      IDENT = /\A[A-Za-z_$][A-Za-z0-9_$]*\z/

      private def self.ts_member(name : String) : String
        name.matches?(IDENT) ? name : name.inspect
      end

      # One typed stub signature (no body, no trailing separator):
      #
      #   findUser(args: { userId: number }): Promise<User>
      #
      # The function name is the leaf id segment in camelCase (`find_user` →
      # `findUser`); the namespace segments are left verbatim (Crystal module/
      # class names). Arguments are one object keyed by name (the wire payload),
      # so any legal signature is representable — optional (defaulted) args
      # become `name?: T`. A zero-arg procedure takes an optional empty object so
      # it stays callable as `fn()`: a default (`= {}`) in an implementation, an
      # optional param (`args?: {}`) in a declaration, where initializers aren't
      # allowed.
      private def self.signature(seg : String, proc : ProcedureDescriptor, known : Hash(String, String), declaration : Bool) : String
        if proc.args.empty?
          param = declaration ? "args?: {}" : "args: {} = {}"
        else
          fields = proc.args.map do |a|
            "#{a.name}#{a.optional ? "?" : ""}: #{Codegen.crystal_to_ts(a.type, known)}"
          end
          param = "args: { #{fields.join("; ")} }"
        end
        "#{seg.camelcase(lower: true)}(#{param}): Promise<#{Codegen.return_to_ts(proc.return_type, known)}>"
      end
    end
  end
end
