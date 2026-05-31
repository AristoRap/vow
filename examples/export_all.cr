require "../src/vow"

# `include Vow::Exportable::All` exports EVERY public method — no per-method
# @[Vow::Export] needed. The annotation is still honored for renames (name:)
# and opt-outs (skip:).
class Calculator
  include Vow::Exportable::All

  # Auto-exported as "Calculator.add" — no annotation required.
  def add(a : Int32, b : Int32) : Int32
    a + b
  end

  # Auto-exported, but renamed for the wire.
  @[Vow::Export(name: "calc.subtract")]
  def sub(a : Int32, b : Int32) : Int32
    a - b
  end

  # Public, but explicitly kept off the wire.
  @[Vow::Export(skip: true)]
  def debug_state : String
    "internal"
  end

  # Private/protected methods are never exported — no annotation needed.
  private def carry(x : Int32) : Int32
    x
  end
end

registry = Vow::Registry.new(Calculator.new)

def show(&block : -> String)
  puts block.call
rescue ex : Vow::Error
  puts "#{ex.code}: #{ex.message}"
end

puts "exported: #{registry.names.sort}"
# => exported: ["Calculator.add", "calc.subtract"]

show { registry.dispatch("Calculator.add", %({"a": 3, "b": 4})) }  # 7
show { registry.dispatch("calc.subtract", %({"a": 10, "b": 4})) }  # 6
show { registry.dispatch("Calculator.debugState", %({})) }         # not_found (skipped)
show { registry.dispatch("Calculator.carry", %({"x": 1})) }        # not_found (private)
