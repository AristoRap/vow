require "json"
require "./registry"
require "./mountable"
require "./manifest"
require "./codegen/collect"

module Vow
  # Marks an instance method as dispatchable across the Vow boundary, and tunes
  # how a method is treated:
  #
  #   * `name:` overrides the registered procedure id (otherwise it's the
  #     `<ClassPath with :: as .>.<method camelCased>` default).
  #   * `skip:` excludes a method that would otherwise be exported. Only
  #     meaningful under `Vow::Exportable::All`, where public methods export by
  #     default — `@[Vow::Export(skip: true)]` keeps one off the wire.
  #
  # On its own the annotation does nothing; the behavior comes from the mixin:
  #
  #   include Vow::Exportable        # export ONLY the @[Vow::Export] methods
  #   include Vow::Exportable::All   # export EVERY public method; annotation optional
  #
  #   @[Vow::Export]                  # => "API.greet"
  #   @[Vow::Export(name: "hello")]   # => "hello"
  #   @[Vow::Export(skip: true)]      # excluded under Exportable::All
  annotation Export; end

  # `include Vow::Exportable` turns a class into a dispatch surface whose wire
  # methods are exactly the ones you annotate with `@[Vow::Export]`. Everything
  # else stays private to Crystal. This is the explicit, opt-in flavor.
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
  # The compiler generates the dispatch glue via `Vow::Exportable::Generated`
  # (see there for what `vow_install` / `vow_descriptors` / `vow_types` do and
  # the compile-time contract every exported signature must satisfy).
  module Exportable
    include ::Vow::Mountable

    macro included
      include ::Vow::Exportable::Generated
    end
  end

  # `include Vow::Exportable::All` exports EVERY public method by default — no
  # per-method annotation required. `@[Vow::Export(name:)]` still renames a
  # method, and `@[Vow::Export(skip: true)]` (or simply making the method
  # `private`/`protected`) keeps one off the wire.
  #
  #   class API
  #     include Vow::Exportable::All
  #
  #     def greet(name : String) : String   # auto-exported as "API.greet"
  #       "Hello, #{name}!"
  #     end
  #
  #     @[Vow::Export(name: "v1.add")]       # auto-exported, renamed
  #     def add(a : Int32, b : Int32) : Int32
  #       a + b
  #     end
  #
  #     private def secret : String          # never exported
  #       "nope"
  #     end
  #   end
  #
  # Only "plain" public methods are picked up automatically: operators (`+`,
  # `[]`), setters (`name=`), predicate/bang methods (`valid?`, `save!`), and
  # Vow's own `vow_*` internals are skipped by default. Any of THOSE can still be
  # force-exported by annotating it with an explicit `@[Vow::Export]` (give it a
  # clean `name:` for a usable wire id).
  #
  # `initialize` is different — it's a HARD block: a constructor can't be a
  # procedure, so it's never exported, and an explicit `@[Vow::Export]` on it is
  # a compile-time error rather than a silent no-op (a bare `@[Vow::Export(skip:
  # true)]` is allowed but redundant). Class methods (`def self.foo`) are simply
  # invisible — the macro only ever inspects instance methods.
  #
  # Because every exported signature must be fully typed (see the contract in
  # `Generated`), opting a class into `All` means committing to typed args and
  # an explicit return type on every public method — that's the price of a
  # trustworthy generated client.
  module Exportable::All
    include ::Vow::Mountable

    macro included
      include ::Vow::Exportable::Generated
    end
  end

  # The shared macro engine. Both `Vow::Exportable` and `Vow::Exportable::All`
  # route through this by emitting `include ::Vow::Exportable::Generated` into
  # the user's class, so its `included` hook fires with `@type` set to that
  # class. The hook generates, from the class's methods:
  #
  #   * `vow_install(registry)` — registers each exported method as a
  #     `Vow::Procedure` whose callback asserts named args, decodes each into
  #     its declared type (typed `bad_input` on failure, honoring defaults),
  #     invokes the real method, and JSON-encodes the result. Called for you by
  #     `Registry#mount`.
  #   * `self.vow_descriptors` — the static `Vow::ProcedureDescriptor`s for the
  #     same methods, readable without an instance, for codegen.
  #   * `self.vow_types` — the custom surface types reachable from those
  #     signatures, transitively, for codegen.
  #
  # The set of "exported methods" is mode-dependent, and the mode is read at
  # *expansion* time (not include time) from `@type.ancestors`: a class that
  # mixed in `Vow::Exportable::All` exports every plain public method plus any
  # annotated one; otherwise only the annotated ones. `@[Vow::Export(skip:)]`
  # excludes a method in either mode.
  #
  # A `macro finished` hook validates every *exported* signature once, for the
  # whole class, regardless of whether anything is ever mounted: each arg must
  # be type-restricted and the return type must be declared — so we never infer
  # or guess, and never emit a descriptor we can't stand behind.
  module Exportable::Generated
    macro included
      # Whole-class validation. `macro finished` runs after the entire program
      # is parsed, so `@type.methods` is complete and the checks fire even for a
      # service that's defined but never mounted. Everything here is escaped
      # (`\{% %}`) so it expands at finish time, where `@type` is the user class.
      macro finished
        \{% begin %}
          \{% all_mode = @type.ancestors.includes?(::Vow::Exportable::All) %}
          \{% ident = "abcdefghijklmnopqrstuvwxyz_ABCDEFGHIJKLMNOPQRSTUVWXYZ" %}
          \{% for m in @type.methods %}
            \{% ann = m.annotation(::Vow::Export) %}
            \{% skip = ann && ann[:skip] %}
            \{% nm = m.name.stringify %}
            # A "plain" public method is one Exportable::All picks up on its
            # own: public, concrete, identifier-named (no operator/setter/
            # predicate/bang), not `initialize`, and not one of Vow's own
            # `vow_*` internals (which `Generated` itself defines).
            \{% forbidden = nm == "initialize" %}
            \{% plain = m.visibility == :public && !m.abstract? && !forbidden &&
                        !nm.starts_with?("vow_") && ident.includes?(nm[0...1]) &&
                        !nm.ends_with?("=") && !nm.ends_with?("?") && !nm.ends_with?("!") %}
            # `initialize` is a hard block: even an explicit @[Vow::Export] can't
            # export a constructor, so annotating it is a mistake we surface loudly
            # rather than silently ignore. (`skip: true` is a no-op, allowed.)
            \{% if forbidden && ann && !skip %}
              \{% raise "Vow: `#{@type}##{m.name}` is a constructor and can't be exported. " +
                        "Remove its @[Vow::Export] annotation." %}
            \{% end %}
            \{% selected = !skip && !forbidden && (all_mode ? (plain || (ann != nil)) : (ann != nil)) %}
            \{% if selected %}
              # How to stop exporting a method, phrased for the mode in play.
              \{% off = all_mode ? "make it `private`/`protected`, or add @[Vow::Export(skip: true)]" : "remove @[Vow::Export]" %}
              # Unsupported signature shapes are rejected loudly rather than
              # silently miscompiled. A named splat would need an array-valued
              # key + variadic expansion; a double splat an open object; a block
              # has no JSON representation. A *bare* `*` (named-only separator)
              # is fine — the args after it cross the boundary as ordinary named
              # args. TODO(vow): support `*splat` and `**double_splat`.
              \{% if (si = m.splat_index) && !m.args[si].name.stringify.empty? %}
                \{% raise "Vow: exported method `#{@type}##{m.name}` has a splat argument `*#{m.args[si].name}`, " +
                          "which Vow can't export yet. Use explicit named arguments, or #{off.id}." %}
              \{% end %}
              \{% unless m.double_splat.is_a?(Nop) %}
                \{% raise "Vow: exported method `#{@type}##{m.name}` has a double-splat argument `**#{m.double_splat}`, " +
                          "which Vow can't export yet. Use explicit named arguments, or #{off.id}." %}
              \{% end %}
              \{% unless m.block_arg.is_a?(Nop) %}
                \{% raise "Vow: exported method `#{@type}##{m.name}` takes a block, which can't cross the JSON " +
                          "boundary. Remove the block parameter, or #{off.id}." %}
              \{% end %}
              \{% for arg in m.args %}
                # Skip the bare-splat slot (empty name): it carries no type and
                # isn't an argument, just a named-only marker.
                \{% if arg.name.stringify.empty? %}
                \{% elsif arg.restriction.stringify.empty? %}
                  \{% raise "Vow: exported method `#{@type}##{m.name}` has an untyped argument `#{arg.name}`. " +
                            "Vow decodes each argument from JSON into its declared type, so every exported arg needs a " +
                            "type restriction — e.g. `def #{m.name}(#{arg.name} : String)`. Or #{off.id}." %}
                \{% end %}
              \{% end %}
              \{% if m.return_type.stringify.empty? %}
                \{% raise "Vow: exported method `#{@type}##{m.name}` has no declared return type. " +
                          "Vow generates client stubs from the signature, so the return type must be explicit — " +
                          "e.g. `def #{m.name}(...) : String`. Use `: Nil` if it returns nothing. Or #{off.id}." %}
              \{% end %}
              # Any other `@[Vow::Export]` keyword (besides the reserved `name:`
              # and `skip:`) is swept into the opaque `opts` bag at descriptor
              # time and carried verbatim. Vow validates nothing about it — a key
              # like `verb:` only means something to a downstream transport, so
              # it's not Vow's place to allowlist values. See `vow_descriptors`.
            \{% end %}
          \{% end %}
        \{% end %}
      end

      def vow_install(registry : ::Vow::Registry) : Nil
        registry.add_descriptors(self.class.vow_descriptors)
        registry.add_types(self.class.vow_types)
        {% verbatim do %}
          {% begin %}
            {% all_mode = @type.ancestors.includes?(::Vow::Exportable::All) %}
            {% ident = "abcdefghijklmnopqrstuvwxyz_ABCDEFGHIJKLMNOPQRSTUVWXYZ" %}
            {% ns = @type.name.stringify.split("::").join(".") %}
            {% for m in @type.methods %}
              {% ann = m.annotation(::Vow::Export) %}
              {% skip = ann && ann[:skip] %}
              {% nm = m.name.stringify %}
              # `initialize` is a hard block: a constructor can't be a procedure,
              # so it's never selected even with an explicit @[Vow::Export] (the
              # annotation, which otherwise force-includes, can't override this).
              {% forbidden = nm == "initialize" %}
              {% plain = m.visibility == :public && !m.abstract? && !forbidden &&
                         !nm.starts_with?("vow_") && ident.includes?(nm[0...1]) &&
                         !nm.ends_with?("=") && !nm.ends_with?("?") && !nm.ends_with?("!") %}
              {% selected = !skip && !forbidden && (all_mode ? (plain || (ann != nil)) : (ann != nil)) %}
              {% if selected %}
                # Auto-derived dispatch id: namespace verbatim (Crystal class/
                # module names), method leaf camelCased so the whole wire surface
                # is consistent with the generated client. An explicit
                # `@[Vow::Export(name:)]` is used exactly as written.
                {% proc_name = (ann && ann[:name]) ? ann[:name] : ns + "." + m.name.stringify.camelcase(lower: true) %}
                # A leading parameter typed `Vow::Context` (or a subclass) is the
                # context opt-in: thread the dispatched context into it and keep it
                # out of the JSON-decoded args. Detect only on a plain type path so a
                # union/generic first arg can't trip `.resolve`.
                {% ctx = false %}
                {% if m.args.size > 0 && (r = m.args[0].restriction).is_a?(Path) %}
                  {% rr = r.resolve %}
                  {% ctx = rr == ::Vow::Context || rr.ancestors.includes?(::Vow::Context) %}
                {% end %}
                # Real arguments to decode: drop the context param and any
                # bare-splat (empty-name) named-only marker.
                {% payload = (ctx ? m.args[1..-1] : m.args).reject { |a| a.name.stringify.empty? } %}
                registry.register({{ proc_name }}) do |__args, __ctx|
                  {% for arg, i in payload %}
                    # The wire key is the caller-facing name in camelCase
                    # (idiomatic JS, and what the generated client sends); the
                    # Crystal call below still binds the real parameter name.
                    # An arg with a default is optional: when the caller omits
                    # the key, fall back to the signature's default value.
                    {% key = arg.name.stringify.camelcase(lower: true) %}
                    {% if arg.default_value.is_a?(Nop) %}
                      unless __args.has_key?({{ key }})
                        raise ::Vow::Error.bad_input(
                          "#{{{ proc_name }}} is missing required argument {{ key.id }}"
                        )
                      end
                      __arg{{ i }} = ::Vow::Registry.decode({{ arg.restriction }}, __args[{{ key }}])
                    {% else %}
                      __arg{{ i }} =
                        if __args.has_key?({{ key }})
                          ::Vow::Registry.decode({{ arg.restriction }}, __args[{{ key }}])
                        else
                          {{ arg.default_value }}
                        end
                    {% end %}
                  {% end %}
                  # Call all named (by caller-facing name) so named-only args
                  # and external names work; context goes in positionally first.
                  {% call_args = [] of _ %}
                  {% if ctx %}{% call_args << "__ctx.as(#{m.args[0].restriction})" %}{% end %}
                  {% for arg, i in payload %}{% call_args << "#{arg.name}: __arg#{i}" %}{% end %}
                  __result = {{ m.name.id }}({{ call_args.join(", ").id }})
                  JSON.parse(__result.to_json)
                end
              {% end %}
            {% end %}
          {% end %}
        {% end %}
      end

      def self.vow_descriptors : Array(::Vow::ProcedureDescriptor)
        {% verbatim do %}
          {% begin %}
            __descriptors = [] of ::Vow::ProcedureDescriptor
            {% all_mode = @type.ancestors.includes?(::Vow::Exportable::All) %}
            {% ident = "abcdefghijklmnopqrstuvwxyz_ABCDEFGHIJKLMNOPQRSTUVWXYZ" %}
            {% ns = @type.name.stringify.split("::").join(".") %}
            {% for m in @type.methods %}
              {% ann = m.annotation(::Vow::Export) %}
              {% skip = ann && ann[:skip] %}
              {% nm = m.name.stringify %}
              # `initialize` is a hard block: a constructor can't be a procedure,
              # so it's never selected even with an explicit @[Vow::Export] (the
              # annotation, which otherwise force-includes, can't override this).
              {% forbidden = nm == "initialize" %}
              {% plain = m.visibility == :public && !m.abstract? && !forbidden &&
                         !nm.starts_with?("vow_") && ident.includes?(nm[0...1]) &&
                         !nm.ends_with?("=") && !nm.ends_with?("?") && !nm.ends_with?("!") %}
              {% selected = !skip && !forbidden && (all_mode ? (plain || (ann != nil)) : (ann != nil)) %}
              {% if selected %}
                # Auto-derived dispatch id: namespace verbatim (Crystal class/
                # module names), method leaf camelCased so the whole wire surface
                # is consistent with the generated client. An explicit
                # `@[Vow::Export(name:)]` is used exactly as written.
                {% proc_name = (ann && ann[:name]) ? ann[:name] : ns + "." + m.name.stringify.camelcase(lower: true) %}
                # Exclude a leading `Vow::Context` param: it's injected by the
                # transport, not sent by the client, so it must not appear in the
                # manifest or the generated stub signature.
                {% ctx = false %}
                {% if m.args.size > 0 && (r = m.args[0].restriction).is_a?(Path) %}
                  {% rr = r.resolve %}
                  {% ctx = rr == ::Vow::Context || rr.ancestors.includes?(::Vow::Context) %}
                {% end %}
                {% payload = (ctx ? m.args[1..-1] : m.args).reject { |a| a.name.stringify.empty? } %}
                # The opaque opts bag: every `@[Vow::Export]` keyword except the
                # reserved `name:`/`skip:`, carried verbatim. Vow attaches no
                # meaning and validates nothing — a key like `verb:` only matters
                # to a downstream transport. Each value keeps its literal type so
                # it round-trips faithfully: a symbol normalizes to its string
                # (`:get` → `"get"`, no leading colon, matching JS expectations),
                # a number stays a number (int vs float by the presence of a `.`),
                # a bool stays a bool, a string stays a string. Built as runtime
                # statements (a fresh `%opts` per method) because `JSON::Any` is
                # constructed at init time, not in the macro AST.
                %opts = {} of String => ::JSON::Any
                {% if ann %}
                  {% for k, v in ann.named_args %}
                    {% unless k == "name" || k == "skip" %}
                      {% if v.is_a?(SymbolLiteral) %}
                        %opts[{{ k.stringify }}] = ::JSON::Any.new({{ v.id.stringify }})
                      {% elsif v.is_a?(StringLiteral) || v.is_a?(BoolLiteral) %}
                        %opts[{{ k.stringify }}] = ::JSON::Any.new({{ v }})
                      {% elsif v.is_a?(NumberLiteral) %}
                        {% if v.stringify.includes?(".") %}
                          %opts[{{ k.stringify }}] = ::JSON::Any.new({{ v }}.to_f64)
                        {% else %}
                          %opts[{{ k.stringify }}] = ::JSON::Any.new({{ v }}.to_i64)
                        {% end %}
                      {% else %}
                        %opts[{{ k.stringify }}] = ::JSON::Any.new({{ v.id.stringify }})
                      {% end %}
                    {% end %}
                  {% end %}
                {% end %}
                __descriptors << ::Vow::ProcedureDescriptor.new(
                  name: {{ proc_name }},
                  opts: %opts,
                  args: [
                    {% for arg in payload %}
                      # The arg name is the caller-facing wire key in camelCase
                      # — the same key the generated client sends and the
                      # callback decodes, so the manifest is the single contract.
                      # `.resolve.stringify` (not the raw AST) so every type
                      # string in the manifest is in one canonical form — the
                      # same form `Codegen.collect` records for type fields, so
                      # references and captured types match exactly. `optional`
                      # is true when the arg has a default value (the caller may
                      # omit it).
                      ::Vow::ArgDescriptor.new(
                        {{ arg.name.stringify.camelcase(lower: true) }},
                        {{ arg.restriction.resolve.stringify }},
                        {{ !arg.default_value.is_a?(Nop) }},
                      ),
                    {% end %}
                  ] of ::Vow::ArgDescriptor,
                  return_type: {{ m.return_type.resolve.stringify }},
                )
              {% end %}
            {% end %}
            __descriptors
          {% end %}
        {% end %}
      end

      # The custom surface types reachable from this service's exported
      # signatures (transitively, deduped). Static — no instance needed.
      # Unions are unwrapped here, at the top-level call site, for the same
      # reason as inside `Codegen.collect`: a union can't survive macro-call
      # interpolation as a resolvable node.
      def self.vow_types : Array(::Vow::TypeDescriptor)
        __types = [] of ::Vow::TypeDescriptor
        {% verbatim do %}
          {% begin %}
            {% all_mode = @type.ancestors.includes?(::Vow::Exportable::All) %}
            {% ident = "abcdefghijklmnopqrstuvwxyz_ABCDEFGHIJKLMNOPQRSTUVWXYZ" %}
            {% for m in @type.methods %}
              {% ann = m.annotation(::Vow::Export) %}
              {% skip = ann && ann[:skip] %}
              {% nm = m.name.stringify %}
              # `initialize` is a hard block: a constructor can't be a procedure,
              # so it's never selected even with an explicit @[Vow::Export] (the
              # annotation, which otherwise force-includes, can't override this).
              {% forbidden = nm == "initialize" %}
              {% plain = m.visibility == :public && !m.abstract? && !forbidden &&
                         !nm.starts_with?("vow_") && ident.includes?(nm[0...1]) &&
                         !nm.ends_with?("=") && !nm.ends_with?("?") && !nm.ends_with?("!") %}
              {% selected = !skip && !forbidden && (all_mode ? (plain || (ann != nil)) : (ann != nil)) %}
              {% if selected %}
                # Skip a leading `Vow::Context` param so its type isn't captured
                # as a surface type that crosses the boundary.
                {% ctx = false %}
                {% if m.args.size > 0 && (r = m.args[0].restriction).is_a?(Path) %}
                  {% rr = r.resolve %}
                  {% ctx = rr == ::Vow::Context || rr.ancestors.includes?(::Vow::Context) %}
                {% end %}
                {% payload = (ctx ? m.args[1..-1] : m.args).reject { |a| a.name.stringify.empty? } %}
                {% sig_types = [m.return_type] + payload.map(&.restriction) %}
                {% for st in sig_types %}
                  {% resolved = st.resolve %}
                  {% if resolved.union? %}
                    {% for u in resolved.union_types %}
                      ::Vow::Codegen.collect(__types, {{ u }}, "")
                    {% end %}
                  {% else %}
                    ::Vow::Codegen.collect(__types, {{ st }}, "")
                  {% end %}
                {% end %}
              {% end %}
            {% end %}
          {% end %}
        {% end %}
        __types.uniq(&.crystal_name)
      end
    end
  end

  # Consumer-driven dispatch registration, for a downstream framework that has
  # its OWN export annotation (Vow knows nothing about it). The framework
  # `include`s this and calls `vow_register_marked(registry, MyAnnotation)` from
  # one of its own instance methods. Because the macro expands in the
  # *consumer's* class context (`@type` is that class), Vow registers every
  # method carrying `marker` with the exact decode → invoke → JSON-encode
  # callback it generates for `@[Vow::Export]` — so the consumer reuses Vow's
  # dispatch instead of reimplementing it, while keeping its own annotation,
  # ids, and any sidecar metadata (async scheduling, routing, …) on the side.
  #
  # The wire id is `<ClassPath with :: as .>.<method camelCased>` and each wire
  # key is the camelCased parameter name — identical to `@[Vow::Export]`. A
  # leading `Vow::Context` (or subclass) parameter opts the method into the
  # per-call context exactly as it does under `@[Vow::Export]`. Arg defaults are
  # honored (an omitted optional key falls back to the signature default).
  #
  # This is intentionally narrower than `@[Vow::Export]`: it does not read the
  # marker's options (the marker is the consumer's own annotation, with its own
  # fields), so there is no `name:`/`skip:`/opts handling — the consumer layers
  # any such concern on top.
  module Exportable::Marked
    macro vow_register_marked(registry, marker)
      {% for m in @type.methods %}
        {% if m.annotation(marker.resolve) %}
          {% ns = @type.name.stringify.split("::").join(".") %}
          {% proc_name = ns + "." + m.name.stringify.camelcase(lower: true) %}
          # A leading `Vow::Context` parameter is the context opt-in: thread the
          # dispatched context into it and keep it out of the decoded args.
          {% ctx = false %}
          {% if m.args.size > 0 && (r = m.args[0].restriction).is_a?(Path) %}
            {% rr = r.resolve %}
            {% ctx = rr == ::Vow::Context || rr.ancestors.includes?(::Vow::Context) %}
          {% end %}
          {% payload = (ctx ? m.args[1..-1] : m.args).reject { |a| a.name.stringify.empty? } %}
          {{ registry }}.register({{ proc_name }}) do |__args, __ctx|
            {% for arg, i in payload %}
              {% key = arg.name.stringify.camelcase(lower: true) %}
              {% if arg.default_value.is_a?(Nop) %}
                unless __args.has_key?({{ key }})
                  raise ::Vow::Error.bad_input("#{{{ proc_name }}} is missing required argument {{ key.id }}")
                end
                __arg{{ i }} = ::Vow::Registry.decode({{ arg.restriction }}, __args[{{ key }}])
              {% else %}
                __arg{{ i }} =
                  if __args.has_key?({{ key }})
                    ::Vow::Registry.decode({{ arg.restriction }}, __args[{{ key }}])
                  else
                    {{ arg.default_value }}
                  end
              {% end %}
            {% end %}
            {% call_args = [] of _ %}
            {% if ctx %}{% call_args << "__ctx.as(#{m.args[0].restriction})" %}{% end %}
            {% for arg, i in payload %}{% call_args << "#{arg.name}: __arg#{i}" %}{% end %}
            __result = {{ m.name.id }}({{ call_args.join(", ").id }})
            JSON.parse(__result.to_json)
          end
        {% end %}
      {% end %}
    end
  end
end
