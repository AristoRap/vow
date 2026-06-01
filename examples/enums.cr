require "../src/vow"

# Enums cross the boundary too. Vow captures an enum referenced by an exported
# signature — directly, or transitively through structs, NamedTuples, arrays,
# unions — and emits it as a TypeScript string-literal *union* `type` alias.
#
# Crucially, the union members are the values each enum member SERIALIZES to
# (`Enum#to_json`), not the Crystal names: Crystal's default lowercases
# (`Red` -> "red"), and a custom `to_json` is reflected verbatim. Vow applies no
# transform of its own, so the generated type always matches the wire.

enum Color
  Red
  Green
  Blue
end

# A custom `to_json` — Vow reflects whatever it produces into the union.
enum Hue
  Warm
  Cool

  def to_json(builder : JSON::Builder)
    builder.string(to_s.upcase)
  end
end

# Reachable ONLY through a struct field: capture descends into it the same way
# it reaches a nested struct.
enum Weight
  Light
  Bold
end

struct Style
  include JSON::Serializable
  getter weight : Weight

  def initialize(@weight)
  end
end

class Palette
  include Vow::Exportable

  # Enum as a plain return value.
  @[Vow::Export]
  def pick(name : String) : Color
    Color::Red
  end

  # Enum as an argument AND nested inside a NamedTuple result.
  @[Vow::Export]
  def swatch(c : Color) : NamedTuple(color: Color, hex: String)
    {color: c, hex: "#ff0000"}
  end

  # Custom-serialized enum, round-tripped.
  @[Vow::Export]
  def tone(h : Hue) : Hue
    h
  end

  # Enum reached only through a struct field.
  @[Vow::Export]
  def styled : Style
    Style.new(Weight::Bold)
  end
end

registry = Vow::Registry.new(Palette.new)

# Dispatch works exactly as for any other type — the enum crosses as its
# serialized string.
puts registry.dispatch("Palette.pick", %({"name": "anything"}))            # "red"
puts registry.dispatch("Palette.tone", %({"h": "WARM"}))                   # "WARM"
puts registry.dispatch("Palette.swatch", %({"c": "green"}))                # {"color":"green","hex":"#ff0000"}
puts

# And here is the generated TypeScript: each enum becomes a `type` alias to a
# string-literal union — autocompletable, exhaustively checkable on the client.
ts = Vow::Codegen::TypeScript.emit(registry.manifest)
puts ts.lines.select { |l| l.starts_with?("export type Color") ||
                           l.starts_with?("export type Hue") ||
                           l.starts_with?("export type Weight") }.join("\n")
# => export type Color = "red" | "green" | "blue";
# => export type Hue = "WARM" | "COOL";
# => export type Weight = "light" | "bold";
