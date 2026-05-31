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

def show(&block : -> String)
  puts block.call
rescue ex : Vow::Error
  puts "#{ex.code}: #{ex.message}"
end

# Args cross the wire as a JSON object keyed by argument name (the same shape
# the generated client sends). The result comes back as a JSON string.
show { registry.dispatch("API.greet", %({"name": "world"})) }  # "Hello, world!"
show { registry.dispatch("API.add", %({"a": 3, "b": 4})) }     # 7
show { registry.dispatch("nope", %({})) }                      # not_found
show { registry.dispatch("API.greet", %({})) }                 # bad_input: missing required arg
show { registry.dispatch("API.add", %({"a": "nan", "b": 4})) } # bad_input: decode
show { registry.dispatch("API.greet", %(not json)) }           # bad_input: invalid JSON
