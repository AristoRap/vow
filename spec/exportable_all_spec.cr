require "./spec_helper"

# Coverage for `Vow::Exportable::All` — the export-everything mixin — plus the
# shared `Vow::Mountable` seam. Every scenario here started life as a macro
# probe while the feature was designed; each is pinned as a spec so the edge
# cases can't silently regress.

# A minimal per-call context, owned by this file so the spec runs on its own
# (no lean on a class from another spec file).
class AllSpecContext < Vow::Context
  def initialize(@values : Hash(String, String))
  end

  def [](key : String) : String?
    @values[key]?
  end
end

# A single service exercising the whole selection matrix: what auto-exports,
# what renames, and every shape that must be skipped.
class AllAPI
  include Vow::Exportable::All

  # (1) plain public method, no annotation -> auto-exported as "AllAPI.greet".
  def greet(name : String) : String
    "Hello, #{name}!"
  end

  # (2) multi-word name -> camelCased wire id "AllAPI.getStatus".
  def get_status : String
    "ok"
  end

  # (3) auto-exported AND renamed via the annotation.
  @[Vow::Export(name: "custom.sum")]
  def sum(a : Int32, b : Int32) : Int32
    a + b
  end

  # (4) default arg stays optional under All, same as annotated mode.
  def inc(a : Int32, b : Int32 = 1) : Int32
    a + b
  end

  # (5) a non-plain name (predicate) is force-exported by an explicit
  # annotation, given a clean wire id.
  @[Vow::Export(name: "health")]
  def healthy? : Bool
    true
  end

  # (6) public, but explicitly excluded with skip:.
  @[Vow::Export(skip: true)]
  def internal_state(x : Int32) : Int32
    x
  end

  # (7) private -> never exported (no annotation needed).
  private def helper(x : Int32) : Int32
    x
  end

  # (8) protected -> never exported.
  protected def guard(x : Int32) : Int32
    x
  end

  # (9) predicate method, unannotated -> skipped.
  def valid?(x : Int32) : Bool
    x > 0
  end

  # (10) bang method, unannotated -> skipped.
  def reset!(x : Int32) : Nil
  end

  # (11) setter -> skipped.
  def label=(v : String) : String
    v
  end

  # (12) operators -> skipped.
  def +(other : AllAPI) : AllAPI
    other
  end

  def [](i : Int32) : Int32
    i
  end

  # (13) declared after every other method (and after the include) -> still
  # seen, because selection is deferred to `macro finished`.
  def late_one(x : Int32) : Int32
    x
  end

  # (14) a CLASS method (here even named `all`) is invisible to @type.methods,
  # so it's never exported and never type-validated — and the name colliding
  # with the Exportable::All module is irrelevant.
  def self.all : Array(Int32)
    [1, 2, 3]
  end
end

# A second all-service returning a custom JSON type, for the types capture.
struct AllPoint
  include JSON::Serializable
  getter x : Int32
  getter y : Int32

  def initialize(@x, @y)
  end
end

class AllShapes
  include Vow::Exportable::All

  def make(x : Int32, y : Int32) : AllPoint
    AllPoint.new(x, y)
  end
end

# An all-service opting into the per-call context (leading Vow::Context param).
class AllCtx
  include Vow::Exportable::All

  def whoami(ctx : Vow::Context) : String
    ctx["user"] || "anonymous"
  end
end

# getter/property generate methods too: the reader auto-exports, the writer
# (a setter) is skipped — proving macro-generated methods flow through the
# same selection rules.
class AllProps
  include Vow::Exportable::All
  getter label : String
  property count : Int32

  def initialize(@label, @count)
  end
end

# An annotated-mode service, to prove `Vow::Exportable` is unchanged and that
# the two flavors mount side by side.
class AnnOnly
  include Vow::Exportable

  @[Vow::Export]
  def a(x : Int32) : Int32
    x
  end

  # No annotation -> NOT exported under Exportable.
  def b(x : Int32) : Int32
    x
  end

  # Annotated but skip: -> NOT exported even though it's annotated.
  @[Vow::Export(skip: true)]
  def c(x : Int32) : Int32
    x
  end
end

# Compiles a standalone snippet and reports {compiled_ok, combined_output}.
# Used to assert the compile-time, fail-loud contract — failures that, by
# design, can't live in the main spec program.
private def vow_compiles(body : String) : {Bool, String}
  # Crystal's `require` resolves by name through CRYSTAL_PATH (absolute-path
  # requires aren't supported), so put the shard's src on the path and
  # `require "vow"`. `--no-codegen` runs semantic analysis only — enough for the
  # macro-finished contract to fire — without producing a binary.
  src_dir = File.expand_path("../src", __DIR__)
  base = IO::Memory.new
  Process.run("crystal", ["env", "CRYSTAL_PATH"], output: base)
  src = File.tempname("vow_all_contract", ".cr")
  File.write(src, %(require "vow"\n#{body}\n))
  outio = IO::Memory.new
  errio = IO::Memory.new
  status = Process.run(
    "crystal", ["build", "--no-codegen", "--no-color", src],
    output: outio, error: errio,
    env: {"CRYSTAL_PATH" => "#{src_dir}:#{base.to_s.strip}"},
  )
  {status.success?, "#{errio}#{outio}"}
ensure
  File.delete(src) if src && File.exists?(src)
end

describe Vow::Exportable::All do
  describe "method selection" do
    registry = Vow::Registry.new(AllAPI.new)

    it "exports every plain public method, annotation optional" do
      registry.names.sort.should eq(
        ["AllAPI.getStatus", "AllAPI.greet", "AllAPI.inc", "AllAPI.lateOne",
         "custom.sum", "health"]
      )
    end

    it "auto-derives <ClassPath>.<camelCased> for an unannotated method" do
      registry.includes?("AllAPI.greet").should be_true
      registry.includes?("AllAPI.getStatus").should be_true
    end

    it "honors @[Vow::Export(name:)] on an auto-exported method" do
      registry.includes?("custom.sum").should be_true
      registry.includes?("AllAPI.sum").should be_false
    end

    it "excludes a public method marked @[Vow::Export(skip: true)]" do
      registry.includes?("AllAPI.internalState").should be_false
    end

    it "excludes private and protected methods" do
      registry.includes?("AllAPI.helper").should be_false
      registry.includes?("AllAPI.guard").should be_false
    end

    it "excludes predicate (?) and bang (!) methods by default" do
      registry.includes?("AllAPI.valid?").should be_false
      registry.includes?("AllAPI.reset!").should be_false
    end

    it "excludes setters and operators" do
      registry.names.any? { |n| n.includes?("label") }.should be_false
      registry.names.any? { |n| n.includes?("+") || n.includes?("[]") }.should be_false
    end

    it "excludes initialize and Vow's own vow_* internals" do
      registry.names.any? { |n| n.downcase.includes?("initialize") }.should be_false
      registry.names.any? { |n| n.downcase.includes?("vow") }.should be_false
    end

    it "force-exports a non-plain method given an explicit annotation" do
      registry.includes?("health").should be_true
    end

    it "sees methods declared after the include" do
      registry.includes?("AllAPI.lateOne").should be_true
    end

    it "never considers class methods (def self.all is not exported)" do
      registry.includes?("AllAPI.all").should be_false
      AllAPI.all.should eq([1, 2, 3]) # still a normal class method
    end
  end

  describe "dispatch (round-trips like annotated mode)" do
    registry = Vow::Registry.new(AllAPI.new)

    it "dispatches an auto-exported method" do
      registry.dispatch("AllAPI.greet", %({"name": "world"})).should eq(%("Hello, world!"))
    end

    it "dispatches a renamed method" do
      registry.dispatch("custom.sum", %({"a": 3, "b": 4})).should eq("7")
    end

    it "applies a default for an omitted optional arg" do
      registry.dispatch("AllAPI.inc", %({"a": 5})).should eq("6")
      registry.dispatch("AllAPI.inc", %({"a": 5, "b": 10})).should eq("15")
    end

    it "dispatches a force-exported predicate under its clean wire name" do
      registry.dispatch("health", %({})).should eq("true")
    end

    it "still raises bad_input for a missing required arg" do
      ex = expect_raises(Vow::Error) { registry.dispatch("AllAPI.greet", %({})) }
      ex.code.should eq("bad_input")
      ex.message.not_nil!.should contain("missing required argument name")
    end
  end

  describe "getter/property generated methods" do
    registry = Vow::Registry.new(AllProps.new("hi", 3))

    it "auto-exports the reader but not the writer" do
      registry.includes?("AllProps.label").should be_true
      registry.includes?("AllProps.count").should be_true
      registry.names.any? { |n| n.includes?("count=") || n.includes?("label=") }.should be_false
    end

    it "dispatches a generated getter" do
      registry.dispatch("AllProps.count", %({})).should eq("3")
    end
  end

  describe "context opt-in (leading Vow::Context param)" do
    registry = Vow::Registry.new(AllCtx.new)
    ctx = AllSpecContext.new({"user" => "ada"})

    it "auto-exports a context method and threads the context in" do
      registry.dispatch("AllCtx.whoami", %({}), ctx).should eq(%("ada"))
    end

    it "omits the context param from the descriptor" do
      d = AllCtx.vow_descriptors.find { |p| p.name == "AllCtx.whoami" }.not_nil!
      d.args.should be_empty
    end
  end

  describe "static descriptors" do
    it "reflects the same selection as runtime dispatch" do
      names = AllAPI.vow_descriptors.map(&.name).sort
      names.should eq(
        ["AllAPI.getStatus", "AllAPI.greet", "AllAPI.inc", "AllAPI.lateOne",
         "custom.sum", "health"]
      )
    end

    it "marks a defaulted arg optional" do
      d = AllAPI.vow_descriptors.find { |p| p.name == "AllAPI.inc" }.not_nil!
      d.args.map(&.name).should eq(["a", "b"])
      d.args.map(&.optional).should eq([false, true])
    end
  end

  describe "captured surface types" do
    it "collects custom types from an auto-exported signature" do
      AllShapes.vow_types.map(&.crystal_name).should contain("AllPoint")
    end
  end

  describe "Vow::Mountable seam" do
    it "mounts an export-all service via the vararg constructor" do
      Vow::Registry.new(AllAPI.new).names.should contain("AllAPI.greet")
    end

    it "mounts annotated and export-all services into one registry" do
      registry = Vow::Registry.new(AllAPI.new, AnnOnly.new)
      registry.names.should contain("AllAPI.greet")
      registry.names.should contain("AnnOnly.a")
    end

    it "chainably mounts an export-all service" do
      registry = Vow::Registry.new
      registry.mount(AllAPI.new).should be(registry)
    end
  end

  describe "Vow.discovered_manifest" do
    names = Vow.discovered_manifest.procedures.map(&.name)

    it "includes export-all services with no boilerplate" do
      names.should contain("AllAPI.greet")
      names.should contain("custom.sum")
    end

    it "excludes the skipped and unexported methods" do
      names.should_not contain("AllAPI.internalState")
      names.should_not contain("AllAPI.helper")
    end
  end

  describe "compile-time contract (fail loud, never lie)" do
    it "compiles a fully-typed export-all service" do
      ok, _ = vow_compiles(<<-CR)
        class Ok
          include Vow::Exportable::All
          def go(x : Int32) : Int32
            x
          end
        end
        CR
      ok.should be_true
    end

    it "rejects a plain public method with an untyped argument" do
      ok, out = vow_compiles(<<-CR)
        class BadArg
          include Vow::Exportable::All
          def go(x) : Int32
            x.as(Int32)
          end
        end
        CR
      ok.should be_false
      out.should contain("untyped argument")
    end

    it "rejects a plain public method with no declared return type" do
      ok, out = vow_compiles(<<-CR)
        class BadReturn
          include Vow::Exportable::All
          def go(x : Int32)
            x
          end
        end
        CR
      ok.should be_false
      out.should contain("no declared return type")
    end

    it "points the user at private/skip to opt a method out" do
      ok, out = vow_compiles(<<-CR)
        class BadHint
          include Vow::Exportable::All
          def go(x) : Int32
            x.as(Int32)
          end
        end
        CR
      ok.should be_false
      out.should contain("skip: true")
    end

    # initialize is a HARD block — auto-skipped, and not even an explicit
    # annotation can force a constructor onto the wire.
    it "auto-skips a plain initialize (no annotation needed)" do
      ok, _ = vow_compiles(<<-CR)
        class OkInit
          include Vow::Exportable::All
          def initialize(@x : Int32); end
          def go : Int32; @x; end
        end
        CR
      ok.should be_true
    end

    it "rejects an @[Vow::Export]-annotated initialize under Exportable::All" do
      ok, out = vow_compiles(<<-CR)
        class BadInit
          include Vow::Exportable::All
          @[Vow::Export]
          def initialize(@x : Int32); end
          def go : Int32; @x; end
        end
        CR
      ok.should be_false
      out.should contain("constructor and can't be exported")
    end

    it "rejects an @[Vow::Export]-annotated initialize under Exportable too" do
      ok, out = vow_compiles(<<-CR)
        class BadInit2
          include Vow::Exportable
          @[Vow::Export]
          def initialize(@x : Int32); end
        end
        CR
      ok.should be_false
      out.should contain("constructor")
    end

    it "allows skip: true on initialize as a harmless no-op" do
      ok, _ = vow_compiles(<<-CR)
        class SkipInit
          include Vow::Exportable::All
          @[Vow::Export(skip: true)]
          def initialize(@x : Int32); end
          def go : Int32; @x; end
        end
        CR
      ok.should be_true
    end
  end
end

# `Vow::Exportable` (annotated mode) must be unchanged: still opt-in, and skip:
# still wins over the annotation.
describe Vow::Exportable do
  registry = Vow::Registry.new(AnnOnly.new)

  it "exports only annotated methods" do
    registry.includes?("AnnOnly.a").should be_true
    registry.includes?("AnnOnly.b").should be_false
  end

  it "lets skip: override an explicit annotation" do
    registry.includes?("AnnOnly.c").should be_false
  end
end
