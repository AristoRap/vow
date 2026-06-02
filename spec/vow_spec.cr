require "./spec_helper"

# A service wired entirely by the macro — no hand-written register blocks.
class TestAPI
  include Vow::Exportable

  @[Vow::Export]
  def greet(name : String) : String
    "Hello, #{name}!"
  end

  @[Vow::Export]
  def add(a : Int32, b : Int32) : Int32
    a + b
  end

  # A default makes `b` optional — the caller may omit it.
  @[Vow::Export]
  def inc(a : Int32, b : Int32 = 1) : Int32
    a + b
  end

  # A default *before* a required arg — only representable with named args.
  @[Vow::Export]
  def span(from : Int32 = 0, to : Int32 = 10) : Int32
    to - from
  end

  # A bare `*` makes `b` named-only; it still crosses as an ordinary named arg.
  @[Vow::Export]
  def diff(a : Int32, *, b : Int32) : Int32
    a - b
  end

  # An external argument name: the caller-facing key is `to`, not `recipient`.
  @[Vow::Export]
  def mail(to recipient : String) : String
    "to #{recipient}"
  end

  # Multi-word arg names: the wire keys are camelCased (`roomId`, `guestCount`).
  @[Vow::Export]
  def book(room_id : Int32, guest_count : Int32 = 1) : String
    "room #{room_id} x#{guest_count}"
  end

  @[Vow::Export]
  def ping : String
    "pong"
  end

  @[Vow::Export(name: "custom.name")]
  def renamed : Int32
    42
  end

  # Opts are an opaque side channel: `verb`/`timeout` are just keys Vow carries
  # verbatim into the descriptor (a downstream HTTP transport might route `verb:
  # :get` as GET). Vow attaches no meaning and validates nothing. `timeout: 30`
  # keeps its number type; `name:`/`skip:` are reserved and never land in opts.
  @[Vow::Export(verb: :get, timeout: 30)]
  def status : String
    "ok"
  end

  # Opts also carry an explicit `verb: :post` verbatim — Vow doesn't treat it as
  # special or as "the default"; it's just another key.
  @[Vow::Export(verb: :post)]
  def reset : Bool
    true
  end

  # No annotation — must NOT be registered.
  def secret : String
    "nope"
  end
end

# A minimal concrete context for exercising the opt-in passthrough.
class TestContext < Vow::Context
  def initialize(@values : Hash(String, String))
  end

  def [](key : String) : String?
    @values[key]?
  end
end

# A service whose methods opt into the per-call context by declaring a leading
# `Vow::Context` parameter. The context arg is transport-injected, never sent by
# the client, so it must be invisible to arg-counting, the manifest, and codegen.
class CtxAPI
  include Vow::Exportable

  @[Vow::Export]
  def whoami(ctx : Vow::Context) : String
    ctx["user"] || "anonymous"
  end

  @[Vow::Export]
  def echo(ctx : Vow::Context, value : String) : String
    "#{ctx["user"]}:#{value}"
  end
end

describe Vow do
  describe "macro-generated dispatch" do
    registry = Vow::Registry.new(TestAPI.new)

    it "registers only @[Vow::Export] methods, under <ClassPath>.<method>" do
      registry.names.sort.should eq(
        ["TestAPI.add", "TestAPI.book", "TestAPI.diff", "TestAPI.greet",
         "TestAPI.inc", "TestAPI.mail", "TestAPI.ping", "TestAPI.reset",
         "TestAPI.span", "TestAPI.status", "custom.name"]
      )
      registry.includes?("TestAPI.secret").should be_false
    end

    it "dispatches a single-arg call by name" do
      registry.dispatch("TestAPI.greet", %({"name": "world"})).should eq(%("Hello, world!"))
    end

    it "dispatches a multi-arg call with typed decoding" do
      registry.dispatch("TestAPI.add", %({"a": 3, "b": 4})).should eq("7")
    end

    it "dispatches a zero-arg call" do
      registry.dispatch("TestAPI.ping", %({})).should eq(%("pong"))
    end

    it "honors @[Vow::Export(name:)] override" do
      registry.dispatch("custom.name", %({})).should eq("42")
    end

    it "applies a default when an optional arg is omitted" do
      registry.dispatch("TestAPI.inc", %({"a": 5})).should eq("6")
    end

    it "uses a supplied value over the default" do
      registry.dispatch("TestAPI.inc", %({"a": 5, "b": 10})).should eq("15")
    end

    it "lets a defaulted arg be omitted even before a required-looking one" do
      registry.dispatch("TestAPI.span", %({"to": 7})).should eq("7")   # from defaults to 0
      registry.dispatch("TestAPI.span", %({"from": 3})).should eq("7") # to defaults to 10
    end

    it "dispatches a named-only arg (after a bare splat)" do
      registry.dispatch("TestAPI.diff", %({"a": 9, "b": 2})).should eq("7")
    end

    it "keys an externally-named arg by its caller-facing name" do
      registry.dispatch("TestAPI.mail", %({"to": "bob"})).should eq(%("to bob"))
    end

    it "decodes multi-word args under their camelCased wire keys" do
      registry.dispatch("TestAPI.book", %({"roomId": 12, "guestCount": 3})).should eq(%("room 12 x3"))
      registry.dispatch("TestAPI.book", %({"roomId": 12})).should eq(%("room 12 x1")) # guestCount defaults
    end

    it "raises not_found for an unknown procedure" do
      ex = expect_raises(Vow::Error) { registry.dispatch("nope", %({})) }
      ex.code.should eq("not_found")
    end

    it "suggests the nearest registered name on an unknown procedure (did-you-mean)" do
      ex = expect_raises(Vow::Error) { registry.dispatch("TestAPI.gret", %({})) }
      ex.code.should eq("not_found")
      ex.hint.should_not be_nil
      ex.hint.not_nil!.should contain("TestAPI.greet")
    end

    it "omits the suggestion when nothing is close enough" do
      ex = expect_raises(Vow::Error) { registry.dispatch("xQz", %({})) }
      ex.hint.should be_nil
    end

    it "raises bad_input naming a missing required arg" do
      ex = expect_raises(Vow::Error) { registry.dispatch("TestAPI.greet", %({})) }
      ex.code.should eq("bad_input")
      ex.message.not_nil!.should contain("missing required argument name")
    end

    it "raises bad_input when an arg can't decode into its declared type" do
      ex = expect_raises(Vow::Error) { registry.dispatch("TestAPI.add", %({"a": "nan", "b": 4})) }
      ex.code.should eq("bad_input")
    end

    it "raises bad_input on invalid JSON" do
      ex = expect_raises(Vow::Error) { registry.dispatch("TestAPI.greet", "not json") }
      ex.code.should eq("bad_input")
    end

    it "raises bad_input when args aren't a JSON object" do
      ex = expect_raises(Vow::Error) { registry.dispatch("TestAPI.greet", %(["x"])) }
      ex.code.should eq("bad_input")
      ex.message.not_nil!.should contain("expected JSON object")
    end
  end

  describe "mounting" do
    it "mounts several services into one registry, chainably" do
      registry = Vow::Registry.new
      registry.mount(TestAPI.new).should be(registry)
      registry.names.should contain("TestAPI.greet")
    end

    it "mounts via the vararg constructor" do
      Vow::Registry.new(TestAPI.new).names.should contain("TestAPI.add")
    end
  end

  describe "context passthrough (opt-in via a leading Vow::Context param)" do
    registry = Vow::Registry.new(CtxAPI.new)
    ctx = TestContext.new({"user" => "ada"})

    it "threads the dispatched context into a context-only method" do
      registry.dispatch("CtxAPI.whoami", %({}), ctx).should eq(%("ada"))
    end

    it "injects context ahead of the client's named args" do
      registry.dispatch("CtxAPI.echo", %({"value": "hi"}), ctx).should eq(%("ada:hi"))
    end

    it "requires only the client-supplied args (context excluded)" do
      ex = expect_raises(Vow::Error) { registry.dispatch("CtxAPI.echo", %({}), ctx) }
      ex.code.should eq("bad_input")
      ex.message.not_nil!.should contain("missing required argument value")
    end

    it "tolerates a nil context for a context-free method" do
      Vow::Registry.new(TestAPI.new).dispatch("TestAPI.ping", %({})).should eq(%("pong"))
    end

    it "omits the context param from the descriptor and its types" do
      d = CtxAPI.vow_descriptors.find { |p| p.name == "CtxAPI.echo" }.not_nil!
      d.args.map(&.name).should eq(["value"])
      d.args.map(&.type).should eq(["String"])
      CtxAPI.vow_types.map(&.crystal_name).should_not contain("Vow::Context")
    end
  end

  describe "manifest (static, no instance needed for descriptors)" do
    it "exposes descriptors as a class method" do
      d = TestAPI.vow_descriptors.find { |p| p.name == "TestAPI.add" }.not_nil!
      d.args.map(&.name).should eq(["a", "b"])
      d.args.map(&.type).should eq(["Int32", "Int32"])
      d.args.map(&.optional).should eq([false, false])
      d.return_type.should eq("Int32")
    end

    it "marks a defaulted arg as optional in the descriptor" do
      d = TestAPI.vow_descriptors.find { |p| p.name == "TestAPI.inc" }.not_nil!
      d.args.map(&.name).should eq(["a", "b"])
      d.args.map(&.optional).should eq([false, true])
    end

    it "captures a named-only arg and an external name" do
      TestAPI.vow_descriptors.find { |p| p.name == "TestAPI.diff" }.not_nil!
        .args.map(&.name).should eq(["a", "b"])
      TestAPI.vow_descriptors.find { |p| p.name == "TestAPI.mail" }.not_nil!
        .args.map(&.name).should eq(["to"])
    end

    it "records arg names as camelCased wire keys" do
      d = TestAPI.vow_descriptors.find { |p| p.name == "TestAPI.book" }.not_nil!
      d.args.map(&.name).should eq(["roomId", "guestCount"])
    end

    it "captures the @[Vow::Export(name:)] override in the descriptor" do
      TestAPI.vow_descriptors.map(&.name).should contain("custom.name")
    end

    it "records the raw Crystal return type verbatim" do
      TestAPI.vow_descriptors.find { |p| p.name == "TestAPI.greet" }.not_nil!.return_type.should eq("String")
    end

    it "leaves opts empty when no extra keyword is given" do
      TestAPI.vow_descriptors.find { |p| p.name == "TestAPI.add" }.not_nil!.opts.should be_empty
    end

    it "carries an arbitrary keyword (verb) verbatim as an opt, normalizing a symbol to its string" do
      TestAPI.vow_descriptors.find { |p| p.name == "TestAPI.status" }.not_nil!.opts["verb"].as_s.should eq("get")
    end

    it "carries an explicit verb: :post verbatim, without treating it as special" do
      TestAPI.vow_descriptors.find { |p| p.name == "TestAPI.reset" }.not_nil!.opts["verb"].as_s.should eq("post")
    end

    it "keeps a numeric opt as a number (not a stringified one)" do
      TestAPI.vow_descriptors.find { |p| p.name == "TestAPI.status" }.not_nil!.opts["timeout"].as_i.should eq(30)
    end

    it "never sweeps the reserved name:/skip: keywords into opts" do
      opts = TestAPI.vow_descriptors.find { |p| p.name == "custom.name" }.not_nil!.opts
      opts.has_key?("name").should be_false
      opts.has_key?("skip").should be_false
    end

    it "round-trips opts through manifest JSON, preserving value types" do
      manifest = Vow::Registry.new(TestAPI.new).manifest
      reparsed = Vow::Manifest.from_json(manifest.to_json)
      opts = reparsed.procedures.find { |p| p.name == "TestAPI.status" }.not_nil!.opts
      opts["verb"].as_s.should eq("get")
      opts["timeout"].as_i.should eq(30)
    end

    it "is reachable from the registry and round-trips through JSON" do
      manifest = Vow::Registry.new(TestAPI.new).manifest
      manifest.procedures.map(&.name).should contain("TestAPI.ping")
      Vow::Manifest.from_json(manifest.to_json).procedures.size.should eq(manifest.procedures.size)
    end

    # The manifest is consumed in JS/TS, so its multi-word JSON keys are
    # camelCase on the wire (`returnType`, `crystalName`) even though the Crystal
    # getters stay snake_case. Pinned here so the wire contract can't drift back.
    it "serializes procedure return type as the camelCase key `returnType`" do
      serialized = Vow::ProcedureDescriptor.new(name: "X.y", args: [] of Vow::ArgDescriptor, return_type: "String").to_json
      serialized.should contain(%("returnType":"String"))
      serialized.should_not contain("return_type")
    end

    it "deserializes the camelCase `returnType` key back into the getter" do
      d = Vow::ProcedureDescriptor.from_json(%({"name":"X.y","args":[],"returnType":"String"}))
      d.return_type.should eq("String")
    end

    it "serializes type descriptor's crystal name as the camelCase key `crystalName`" do
      serialized = Vow::TypeDescriptor.new(name: "Point", crystal_name: "Geo::Point", fields: [] of Vow::FieldDescriptor).to_json
      serialized.should contain(%("crystalName":"Geo::Point"))
      serialized.should_not contain("crystal_name")
    end

    it "deserializes the camelCase `crystalName` key back into the getter" do
      t = Vow::TypeDescriptor.from_json(%({"name":"Point","crystalName":"Geo::Point","fields":[]}))
      t.crystal_name.should eq("Geo::Point")
    end
  end
end
