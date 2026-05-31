require "../error"

module Vow
  module Codegen
    # Raised when a Crystal type can't be mapped to TypeScript accurately.
    # In practice the `Vow::Exportable` macro has already rejected types that
    # can't cross the boundary, so this is defense-in-depth: it fires loudly
    # rather than let the emitter invent a type. Never downgrade this to a
    # silent `any`/`Record<string, any>` fallback — an inaccurate stub is
    # worse than a build error.
    class UnmappableType < Vow::Error
      def initialize(type : String, reason : String)
        super("codegen_unmappable_type",
          "cannot map Crystal type `#{type}` to TypeScript: #{reason}")
      end
    end

    PRIMITIVE_TS = {
      "String" => "string",
      "Bool" => "boolean",
      "Char" => "string",
      "Nil" => "null",
      "Int8" => "number", "Int16" => "number", "Int32" => "number",
      "Int64" => "number", "Int128" => "number",
      "UInt8" => "number", "UInt16" => "number", "UInt32" => "number",
      "UInt64" => "number", "UInt128" => "number",
      "Float32" => "number", "Float64" => "number",
      "JSON::Any" => "any",
    }

    # Maps a raw Crystal type string (as captured in the manifest) to a
    # TypeScript type, recursively. `known` maps a captured type's full Crystal
    # name to the TS interface name to use for it.
    #
    #   "Array(Int32)"            -> "number[]"
    #   "Hash(String, Bool)"      -> "Record<string, boolean>"
    #   "(Inner | Nil)"           -> "Inner | null"
    #   "CounterState" (known)    -> "CounterState"
    #
    # An identifier that is neither a primitive nor in `known` raises
    # `UnmappableType` — it never falls back to `any`.
    def self.crystal_to_ts(type : String, known : Hash(String, String) = {} of String => String) : String
      type = type.strip
      type = unwrap_parens(type)

      members = split_top_level(type, '|')
      if members.size > 1
        return members.map { |m| crystal_to_ts(m, known) }.join(" | ")
      end

      if inner = generic_inner(type, "Array")
        el = crystal_to_ts(inner, known)
        el = "(#{el})" if el.includes?(" | ")
        return "#{el}[]"
      end
      if inner = generic_inner(type, "Set")
        el = crystal_to_ts(inner, known)
        el = "(#{el})" if el.includes?(" | ")
        return "#{el}[]"
      end
      if inner = generic_inner(type, "Hash")
        parts = split_top_level(inner, ',')
        raise UnmappableType.new(type, "Hash needs exactly two type arguments") unless parts.size == 2
        return "Record<#{crystal_to_ts(parts[0], known)}, #{crystal_to_ts(parts[1], known)}>"
      end
      if inner = generic_inner(type, "Tuple")
        return "[#{split_top_level(inner, ',').map { |p| crystal_to_ts(p, known) }.join(", ")}]"
      end
      if inner = generic_inner(type, "NamedTuple")
        fields = split_top_level(inner, ',').map do |pair|
          name, rest = pair.split(":", 2)
          "#{name.strip}: #{crystal_to_ts(rest.strip, known)}"
        end
        return "{ #{fields.join("; ")} }"
      end

      if ts = PRIMITIVE_TS[type]?
        return ts
      end
      if ts = known[type]?
        return ts
      end

      raise UnmappableType.new(type,
        "no built-in mapping and not a captured @[Vow] surface type (did the manifest miss it?)")
    end

    # Render a return type for a client stub: `Nil` becomes `void` (rather than
    # `null`), everything else maps normally.
    def self.return_to_ts(type : String, known : Hash(String, String) = {} of String => String) : String
      type.strip == "Nil" ? "void" : crystal_to_ts(type, known)
    end

    # Strips one fully-enclosing pair of parens (e.g. "(Inner | Nil)"), leaving
    # "Inner | Nil". Leaves "Array(Int32)" untouched (the parens don't enclose
    # the whole string).
    private def self.unwrap_parens(type : String) : String
      return type unless type.starts_with?('(') && type.ends_with?(')')
      depth = 0
      type.each_char_with_index do |c, i|
        depth += 1 if c == '('
        depth -= 1 if c == ')'
        # If we return to depth 0 before the last char, the leading "(" does
        # not enclose the whole string — bail.
        return type if depth == 0 && i < type.size - 1
      end
      type[1..-2].strip
    end

    # Inner type string of `Name(...)`, or nil if `type` isn't that generic.
    private def self.generic_inner(type : String, name : String) : String?
      prefix = "#{name}("
      return nil unless type.starts_with?(prefix) && type.ends_with?(')')
      type[prefix.size..-2]
    end

    # Splits on `delim` at paren-depth 0, trimming each part.
    private def self.split_top_level(s : String, delim : Char) : Array(String)
      parts = [] of String
      depth = 0
      start = 0
      s.each_char_with_index do |c, i|
        case c
        when '(' then depth += 1
        when ')' then depth -= 1
        when delim
          if depth == 0
            parts << s[start...i].strip
            start = i + 1
          end
        end
      end
      parts << s[start..].strip
      parts.reject(&.empty?)
    end
  end
end
