require "json"
require "../manifest"

module Vow
  module Codegen
    # Crystal types that map to a TypeScript built-in — they don't need to be
    # captured as surface types, and they're the only non-serializable leaves
    # allowed to cross the boundary. Anything else that isn't
    # `JSON::Serializable` is rejected (see the `else` branch below). Kept in
    # sync with `Vow::Codegen.crystal_to_ts`.
    PRIMITIVE_TYPES = [
      "String", "Bool", "Char", "Nil",
      "Int8", "Int16", "Int32", "Int64", "Int128",
      "UInt8", "UInt16", "UInt32", "UInt64", "UInt128",
      "Float32", "Float64",
      "JSON::Any",
    ]

    # Appends a `Vow::TypeDescriptor` to `acc` for every `JSON::Serializable`
    # type reachable from `t`, transitively, walking through generic type args
    # (`Array(T)`, `Hash(K, V)`, …), `NamedTuple` members (by key), and unions
    # (`T?`). `seen` is a `|`-joined
    # path of visited type names that prevents infinite recursion on
    # self-referential types; DAG diamonds may emit a type more than once, so
    # callers dedup by `crystal_name`.
    #
    # The fail-loud contract lives in the `else` branch: a leaf that is neither
    # a built-in primitive nor `JSON::Serializable` can't honestly cross the
    # boundary, so we raise at compile time with a fix rather than let codegen
    # invent a type for it.
    #
    # Unions are unwrapped *inline* at every recursion site (not delegated)
    # because interpolating a union TypeNode through a macro-call argument
    # renders it as a parenthesized expression that can no longer `.resolve`.
    macro collect(acc, t, seen)
      {% r = t.resolve %}
      {% if r < JSON::Serializable %}
        {% key = r.name.stringify %}
        {% unless seen.split("|").includes?(key) %}
          {{ acc }} << ::Vow::TypeDescriptor.new(
            name: {{ key.split("::").last }},
            crystal_name: {{ key }},
            fields: [
              {% for iv in r.instance_vars %}
                {% ann = iv.annotation(::JSON::Field) %}
                # A field marked `ignore: true` never crosses the wire, so it
                # must not appear in the interface. The captured name is the
                # JSON key that actually crosses — honor `@[JSON::Field(key:)]`
                # so the interface can't lie about the field name.
                {% unless ann && ann[:ignore] %}
                  ::Vow::FieldDescriptor.new(
                    {{ (ann && ann[:key]) ? ann[:key] : iv.name.stringify }},
                    {{ iv.type.stringify }},
                  ),
                {% end %}
              {% end %}
            ] of ::Vow::FieldDescriptor,
          )
          {% for iv in r.instance_vars %}
            {% ann = iv.annotation(::JSON::Field) %}
            # Don't recurse into an ignored field's type: it doesn't cross via
            # this field, and walking it could wrongly reject a type that never
            # reaches the boundary.
            {% unless ann && ann[:ignore] %}
              {% if iv.type.union? %}
                {% for u in iv.type.union_types %}
                  ::Vow::Codegen.collect({{ acc }}, {{ u }}, {{ seen + key + "|" }})
                {% end %}
              {% else %}
                ::Vow::Codegen.collect({{ acc }}, {{ iv.type }}, {{ seen + key + "|" }})
              {% end %}
            {% end %}
          {% end %}
        {% end %}
      {% elsif r < Enum %}
        # An enum crosses as a string-literal union of the values its members
        # SERIALIZE to (`Enum#to_json`) — not their Crystal names. The members
        # array is built at runtime from each member's actual `to_json` output
        # (parsed back to its bare string), so the union always matches the wire:
        # Crystal's default lowercases (`Red` → `"red"`), and a custom `to_json`
        # is reflected. vow applies no transform of its own. Member values are
        # leaves, so there's nothing to recurse.
        {% key = r.name.stringify %}
        {% unless seen.split("|").includes?(key) %}
          %members = [] of String
          {% for c in r.constants %}
            %members << ::JSON.parse({{ r }}::{{ c }}.to_json).as_s
          {% end %}
          {{ acc }} << ::Vow::TypeDescriptor.new(
            name: {{ key.split("::").last }},
            crystal_name: {{ key }},
            fields: [] of ::Vow::FieldDescriptor,
            kind: "enum",
            members: %members,
          )
        {% end %}
      {% elsif r.name(generic_args: false).stringify.starts_with?("NamedTuple") %}
        # A NamedTuple is a built-in inline shape (`crystal_to_ts` renders it as
        # `{ ... }`), so it's never captured itself — but it can carry
        # `JSON::Serializable` members that must be. Walk it BY KEY: a
        # NamedTuple's `type_vars` is `[the NamedTuple itself]`, so the
        # `type_vars` branch below would self-recurse forever. `seen` is passed
        # unchanged — each member is a distinct, structurally smaller type, so
        # this terminates.
        {% for k in r.keys %}
          {% if r[k].union? %}
            {% for u in r[k].union_types %}
              ::Vow::Codegen.collect({{ acc }}, {{ u }}, {{ seen }})
            {% end %}
          {% else %}
            ::Vow::Codegen.collect({{ acc }}, {{ r[k] }}, {{ seen }})
          {% end %}
        {% end %}
      {% elsif !r.type_vars.empty? %}
        {% for tv in r.type_vars %}
          {% if tv.union? %}
            {% for u in tv.union_types %}
              ::Vow::Codegen.collect({{ acc }}, {{ u }}, {{ seen }})
            {% end %}
          {% else %}
            ::Vow::Codegen.collect({{ acc }}, {{ tv }}, {{ seen }})
          {% end %}
        {% end %}
      {% else %}
        {% unless ::Vow::Codegen::PRIMITIVE_TYPES.includes?(r.name.stringify) %}
          {% raise "Vow: type `#{r.name}` is referenced by an @[Vow::Export] signature but can't cross the boundary — " +
                   "it's not a built-in and doesn't `include JSON::Serializable`. Add `include JSON::Serializable` to it, " +
                   "or don't expose it across the boundary." %}
        {% end %}
      {% end %}
    end
  end
end
