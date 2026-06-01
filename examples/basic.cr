require "../src/vow"

# Annotate methods, include Vow::Exportable — the macro generates the dispatch glue.
class API
  include Vow::Exportable

  @[Vow::Export]
  def greet(name : String) : String
    "Hello, #{name}!"
  end

  @[Vow::Export]
  def add(a : Int32, b : Int32) : Int32
    a + b
  end
end

registry = Vow::Registry.new(API.new)

# Errors carry a stable `code` plus an optional `hint` — the same shape a
# transport forwards to its client. We print the hint when there is one.
def show(&block : -> String)
  puts block.call
rescue ex : Vow::Error
  puts ex.hint ? "#{ex.code}: #{ex.message} (#{ex.hint})" : "#{ex.code}: #{ex.message}"
end

# Args cross the wire as a JSON object keyed by argument name (the same shape
# the generated client sends). The result comes back as a JSON string.
show { registry.dispatch("API.greet", %({"name": "world"})) }  # "Hello, world!"
show { registry.dispatch("API.add", %({"a": 3, "b": 4})) }     # 7
show { registry.dispatch("nope", %({})) }                      # not_found (too far off — no hint)
show { registry.dispatch("API.greet", %({})) }                 # bad_input: missing required arg
show { registry.dispatch("API.add", %({"a": "nan", "b": 4})) } # bad_input: decode
show { registry.dispatch("API.greet", %(not json)) }           # bad_input: invalid JSON

# A *near-miss* procedure name gets a "did you mean?" hint: dispatch finds the
# closest registered name within an edit-distance tolerance, so a typo'd id is
# diagnosable instead of a bare not_found.
show { registry.dispatch("API.gret", %({"name": "world"})) } # not_found: ... (did you mean "API.greet"?)
