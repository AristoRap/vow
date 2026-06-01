require "./spec_helper"

# A consumer-defined export annotation — Vow knows nothing about it. This proves
# `Vow::Exportable::Marked` lets a downstream framework keep its own annotation
# and still drive Vow's dispatch generation (the seam lune uses for @[Lune::Bind]).
annotation MyExport; end

private class CustomService
  include Vow::Exportable::Marked

  @[MyExport]
  def greet(name : String) : String
    "Hi, #{name}"
  end

  # A default makes `b` optional; multi-word names camelCase on the wire.
  @[MyExport]
  def add(a : Int32, room_id : Int32 = 1) : Int32
    a + room_id
  end

  # No marker — must NOT be registered.
  def secret : String
    "nope"
  end

  # The consumer drives Vow's generation with its OWN annotation, from any
  # instance method (here, a hand-written mount).
  def mount(registry : Vow::Registry) : Nil
    vow_register_marked(registry, MyExport)
  end
end

describe "Vow::Exportable::Marked" do
  it "registers marker-annotated methods with Vow's standard dispatch callback" do
    svc = CustomService.new
    reg = Vow::Registry.new
    svc.mount(reg)

    reg.dispatch("CustomService.greet", %({"name": "Ada"})).should eq(%("Hi, Ada"))
    reg.includes?("CustomService.greet").should be_true
  end

  it "camelCases multi-word wire keys and honors defaults" do
    svc = CustomService.new
    reg = Vow::Registry.new
    svc.mount(reg)

    # roomId omitted -> default 1
    reg.dispatch("CustomService.add", %({"a": 41})).should eq("42")
    reg.dispatch("CustomService.add", %({"a": 40, "roomId": 2})).should eq("42")
  end

  it "leaves unmarked methods off the wire" do
    svc = CustomService.new
    reg = Vow::Registry.new
    svc.mount(reg)
    reg.includes?("CustomService.secret").should be_false
  end

  it "raises bad_input for a missing required arg" do
    svc = CustomService.new
    reg = Vow::Registry.new
    svc.mount(reg)
    expect_raises(Vow::Error, "missing required argument name") do
      reg.dispatch("CustomService.greet", "{}")
    end
  end
end
