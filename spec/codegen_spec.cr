require "./spec_helper"

struct Point
  include JSON::Serializable
  getter x : Int32
  getter y : Int32

  def initialize(@x, @y)
  end
end

struct Shape
  include JSON::Serializable
  getter origin : Point
  getter corners : Array(Point)
  getter label : String?

  def initialize(@origin, @corners, @label)
  end
end

# Exercises field-name fidelity: a `@[JSON::Field(key:)]` rename must appear in
# the interface under the wire key, and an `ignore: true` field must not appear
# at all (it never crosses).
struct Account
  include JSON::Serializable
  getter user_id : Int32
  @[JSON::Field(key: "displayName")]
  getter display_name : String
  @[JSON::Field(ignore: true)]
  getter cached : Int32 = 0

  def initialize(@user_id, @display_name)
  end
end

class Geo
  include Vow::Exportable

  @[Vow::Export]
  def make(x : Int32, y : Int32) : Point
    Point.new(x, y)
  end

  @[Vow::Export]
  def describe(shape : Shape) : String
    shape.label || "shape"
  end

  @[Vow::Export]
  def origins(shapes : Array(Shape)) : Array(Point)
    shapes.map(&.origin)
  end

  # A default makes `scale` optional in the generated stub (`scale?: number`).
  @[Vow::Export]
  def grow(p : Point, scale : Int32 = 2) : Point
    Point.new(p.x * scale, p.y * scale)
  end

  # Multi-word method and arg names: the stub camelCases both
  # (`findAccount`, `accountId`); the namespace `Geo` stays verbatim.
  @[Vow::Export]
  def find_account(account_id : Int32) : Account
    Account.new(account_id, "n/a")
  end

  # An opt declared on the export flows verbatim into the generated stub as an
  # opts bag — here a `verb: :get` of the caller's own choosing (Vow attaches no
  # meaning to the key; a transport's `method` fn is free to read it).
  @[Vow::Export(verb: :get)]
  def lookup(account_id : Int32) : Account
    Account.new(account_id, "n/a")
  end
end

# A zero-arg export, owned by this file, to exercise the args-object defaulting
# in each target (`args = {}` / `args?: {}`). Defined locally rather than
# borrowed from another spec file so this spec runs on its own.
class Beacon
  include Vow::Exportable

  @[Vow::Export]
  def ping : String
    "pong"
  end
end

# A serializable struct reachable ONLY through a NamedTuple member. Capturing it
# proves `collect` walks a NamedTuple return by key. A NamedTuple's `type_vars`
# is `[the NamedTuple itself]`, so a naive type-args walk self-recurses forever;
# capture must descend by key instead, terminate, and pull out nested
# serializable members — while leaving the NamedTuple itself (a built-in inline
# shape) uncaptured.
struct Pin
  include JSON::Serializable
  getter at : Point
  getter note : String

  def initialize(@at, @note)
  end
end

class Atlas
  include Vow::Exportable

  @[Vow::Export]
  def locate(id : Int32) : NamedTuple(label: String, pin: Pin)
    {label: "x", pin: Pin.new(Point.new(id, id), "n")}
  end
end

# A plain enum referenced by an export. vow captures it as a string-literal
# union of the values each member *serializes to* (`Enum#to_json`) — not the
# Crystal member names. Crystal's default lowercases, so `Red` → `"red"`. vow
# applies no transform of its own; it reflects whatever the type serializes to.
# Reached both directly (a return) and through a NamedTuple member.
enum Color
  Red
  Green
  Blue
end

# An enum with a custom `to_json`: vow reflects the custom wire form into the
# union (so the generated type always matches what actually crosses).
enum Hue
  Warm
  Cool

  def to_json(builder : JSON::Builder)
    builder.string(to_s.upcase)
  end
end

# An enum reachable ONLY through a struct field and an Array element — proves
# capture descends into both and reaches the enum leaf the same way it reaches
# a nested struct.
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

  @[Vow::Export]
  def pick(name : String) : Color
    Color::Red
  end

  @[Vow::Export]
  def swatch(c : Color) : NamedTuple(color: Color, hex: String)
    {color: c, hex: "#ff0000"}
  end

  @[Vow::Export]
  def tone(h : Hue) : Hue
    h
  end

  @[Vow::Export]
  def styled : Style
    Style.new(Weight::Bold)
  end

  @[Vow::Export]
  def weights : Array(Weight)
    [Weight::Light, Weight::Bold]
  end
end

describe Vow::Codegen do
  describe "crystal_to_ts" do
    map = ->(t : String) { Vow::Codegen.crystal_to_ts(t) }

    it "maps primitives" do
      map.call("String").should eq("string")
      map.call("Int32").should eq("number")
      map.call("Bool").should eq("boolean")
      map.call("Float64").should eq("number")
    end

    it "maps collections recursively" do
      map.call("Array(String)").should eq("string[]")
      map.call("Hash(String, Int32)").should eq("Record<string, number>")
      map.call("Tuple(String, Int32)").should eq("[string, number]")
      map.call("Array(Hash(String, Bool))").should eq("Record<string, boolean>[]")
    end

    it "maps unions, wrapping array elements" do
      map.call("(Int32 | Nil)").should eq("number | null")
      map.call("Array(Int32 | Nil)").should eq("(number | null)[]")
    end

    it "maps a known surface type to its interface name" do
      Vow::Codegen.crystal_to_ts("Point", {"Point" => "Point"}).should eq("Point")
      Vow::Codegen.crystal_to_ts("Array(Point)", {"Point" => "Point"}).should eq("Point[]")
    end

    it "maps Nil return to void but Nil elsewhere to null" do
      Vow::Codegen.return_to_ts("Nil").should eq("void")
      Vow::Codegen.crystal_to_ts("Nil").should eq("null")
    end

    it "fails loud on an unmappable type instead of emitting any" do
      ex = expect_raises(Vow::Codegen::UnmappableType) { Vow::Codegen.crystal_to_ts("Widget") }
      ex.code.should eq("codegen_unmappable_type")
    end
  end

  describe "type capture" do
    it "captures referenced serializable types transitively, deduped" do
      names = Geo.vow_types.map(&.crystal_name).sort
      names.should eq(["Account", "Point", "Shape"])
    end

    it "records fields as raw Crystal type strings" do
      shape = Geo.vow_types.find { |t| t.crystal_name == "Shape" }.not_nil!
      shape.fields.map(&.name).should eq(["origin", "corners", "label"])
      shape.fields.map(&.type).should eq(["Point", "Array(Point)", "(String | Nil)"])
    end

    it "captures a field under its @[JSON::Field(key:)] wire name" do
      account = Geo.vow_types.find { |t| t.crystal_name == "Account" }.not_nil!
      account.fields.map(&.name).should eq(["user_id", "displayName"])
    end

    it "omits an @[JSON::Field(ignore: true)] field — it never crosses" do
      account = Geo.vow_types.find { |t| t.crystal_name == "Account" }.not_nil!
      account.fields.map(&.name).should_not contain("cached")
    end

    # Regression: a NamedTuple return must be walked by key (terminating) rather
    # than via `type_vars` (which is the NamedTuple itself → infinite recursion).
    # `Pin` and its nested `Point` are captured; the NamedTuple is not.
    it "walks a NamedTuple return by key — captures nested types, not the NamedTuple" do
      Atlas.vow_types.map(&.crystal_name).sort.should eq(["Pin", "Point"])
    end
  end

  describe "TypeScript emit" do
    ts = Vow::Codegen::TypeScript.emit(Vow::Registry.new(Geo.new).manifest)

    it "emits a transport-agnostic createClient factory" do
      ts.should contain("export type VowTransport = (name: string, args: Record<string, unknown>, opts: Record<string, unknown>) => Promise<unknown>;")
      ts.should contain("export function createClient(transport: VowTransport)")
    end

    it "emits an interface per captured type with mapped fields" do
      ts.should contain("export interface Point {")
      ts.should contain("  x: number;")
      ts.should contain("export interface Shape {")
      ts.should contain("  origin: Point;")
      ts.should contain("  corners: Point[];")
      ts.should contain("  label: string | null;")
    end

    it "emits a renamed field under its wire key and drops ignored fields" do
      ts.should contain("export interface Account {")
      ts.should contain("  user_id: number;")
      ts.should contain("  displayName: string;")
      ts.should_not contain("cached")
    end

    it "camelCases the leaf method and arg names (and the dispatch id leaf), keeping the namespace verbatim" do
      ts.should contain(%(findAccount(args: { accountId: number }): Promise<Account> { return transport("Geo.findAccount", args, {}) as Promise<Account>; },))
    end

    it "emits typed object-argument stubs that forward the args to the transport with an empty opts bag" do
      ts.should contain(%(make(args: { x: number; y: number }): Promise<Point> { return transport("Geo.make", args, {}) as Promise<Point>; },))
      ts.should contain("describe(args: { shape: Shape }): Promise<string>")
      ts.should contain("origins(args: { shapes: Shape[] }): Promise<Point[]>")
    end

    it "passes the opts bag (verb) to the transport for a procedure that declares opts" do
      ts.should contain(%(lookup(args: { accountId: number }): Promise<Account> { return transport("Geo.lookup", args, {"verb": "get"}) as Promise<Account>; },))
    end

    it "marks an optional (defaulted) arg with ? in the stub" do
      ts.should contain("grow(args: { p: Point; scale?: number }): Promise<Point>")
    end

    it "nests stubs under the service namespace" do
      ts.should contain("Geo: {")
    end

    it "emits a VowErrorCode union of the built-in codes plus an open arm" do
      Vow::Error::BUILTIN_CODES.each { |code| ts.should contain(code.inspect) }
      ts.should contain("export type VowErrorCode =")
      ts.should contain("| (string & {});") # open arm keeps downstream codes valid
    end

    it "emits a typed VowError class carrying code and hint" do
      ts.should contain("export class VowError extends Error {")
      ts.should contain("readonly code: VowErrorCode;")
      ts.should contain("readonly hint: string | null;")
    end

    it "emits a batteries-included createHttpClient built on createClient" do
      ts.should contain("export interface HttpClientOptions {")
      ts.should contain("headers?: () => Record<string, string>;")                      # per-call header fn
      ts.should contain(%(method?: (opts: Record<string, unknown>) => "GET" | "POST";)) # caller's verb rule
      ts.should contain("export function createHttpClient(url: string, options: HttpClientOptions = {}) {")
      ts.should contain("return createClient(async (name, args, opts) =>") # the escape hatch underneath
      ts.should contain("if (!res.ok) throw new VowError(data.error, data.message, data.hint ?? null);")
    end

    it "derives the method from the caller's method fn (defaulting to POST), naming no opt key itself" do
      ts.should contain(%(const method = options.method?.(opts) ?? "POST";))    # caller maps opts -> verb; Vow names no key
      ts.should contain(%(const path = `${url}/${name.replaceAll(".", "/")}`;)) # dots -> slashes
      ts.should contain(%(?input=${encodeURIComponent(JSON.stringify(args))}))  # GET reads carry args in the query
      ts.should contain(%(body: JSON.stringify(args),))                         # POST writes carry args in the body
      ts.should_not contain("opts.verb")                                        # the client hardcodes no opt key
    end
  end

  describe "JavaScript emit" do
    js = Vow::Codegen::JavaScript.emit(Vow::Registry.new(Geo.new).manifest)

    it "emits an untyped createClient runtime (no type annotations)" do
      js.should contain("export function createClient(transport) {")
      js.should_not contain(": Promise")
      js.should_not contain("VowTransport")
      js.should_not contain("interface")
    end

    it "emits the same camelCased names, namespace, and dispatch ids as the .ts" do
      js.should contain("Geo: {")
      js.should contain(%(findAccount(args) { return transport("Geo.findAccount", args, {}); },))
      js.should contain(%(make(args) { return transport("Geo.make", args, {}); },))
    end

    it "renders the opts bag identically to the .ts stub (byte-for-byte parity)" do
      js.should contain(%(lookup(args) { return transport("Geo.lookup", args, {"verb": "get"}); },))
    end

    it "defaults the args object for a zero-arg stub so it stays callable as fn()" do
      js0 = Vow::Codegen::JavaScript.emit(Vow::Registry.new(Beacon.new).manifest)
      js0.should contain(%(ping(args = {}) { return transport("Beacon.ping", args, {}); },))
    end

    it "emits the VowError class and createHttpClient runtime, untyped" do
      js.should contain("export class VowError extends Error {")
      js.should contain("constructor(code, message, hint = null) {")
      js.should contain("export function createHttpClient(url, options = {}) {")
      js.should contain("return createClient(async (name, args, opts) =>")
      js.should contain(%(const method = options.method?.(opts) ?? "POST";)) # caller's rule, default POST
      js.should contain("if (!res.ok) throw new VowError(data.error, data.message, data.hint ?? null);")
      js.should_not contain("opts.verb")    # the runtime hardcodes no opt key
      js.should_not contain("VowErrorCode") # no type annotations in the runtime
      js.should_not contain(": Promise")
    end
  end

  describe "d.ts emit" do
    dts = Vow::Codegen::TypeScript.emit_dts(Vow::Registry.new(Geo.new).manifest)

    it "declares createClient with no body, plus the shared types" do
      dts.should contain("export type VowTransport = (name: string, args: Record<string, unknown>, opts: Record<string, unknown>) => Promise<unknown>;")
      dts.should contain("export interface Account {")
      dts.should contain("export declare function createClient(transport: VowTransport): {")
      dts.should_not contain("return transport(") # declaration only — no implementation
    end

    it "carries the same typed signatures as the .ts stubs" do
      dts.should contain("findAccount(args: { accountId: number }): Promise<Account>;")
      dts.should contain("grow(args: { p: Point; scale?: number }): Promise<Point>;")
    end

    it "marks a zero-arg stub's object optional (no initializer in a declaration)" do
      dts0 = Vow::Codegen::TypeScript.emit_dts(Vow::Registry.new(Beacon.new).manifest)
      dts0.should contain("ping(args?: {}): Promise<string>;")
    end

    it "declares VowError and createHttpClient (shapes only, no bodies)" do
      dts.should contain("export type VowErrorCode =")
      dts.should contain("export declare class VowError extends Error {")
      dts.should contain("export declare function createHttpClient(url: string, options?: HttpClientOptions): {")
      dts.should_not contain("throw new VowError") # declaration only — no implementation
      dts.should_not contain("return createClient(")
    end

    it "gives createHttpClient the same client shape as createClient" do
      dts.should contain("findAccount(args: { accountId: number }): Promise<Account>;")
      # the typed method shapes appear under both factory declarations
      dts.scan("Geo: {").size.should eq(2)
    end
  end

  # An enum crosses the boundary as a string-literal union of its member names,
  # captured generically (no JSON::Serializable needed) and emitted as a TS
  # `type` alias rather than an `interface`. vow records the values each member
  # SERIALIZES to (`Enum#to_json`) — Crystal's default lowercases, and a custom
  # `to_json` is reflected — so the generated union always matches the wire.
  describe "enum capture and emit" do
    it "captures an enum as a string-literal-union surface type from its serialized values" do
      color = Palette.vow_types.find { |t| t.crystal_name == "Color" }.not_nil!
      color.kind.should eq("enum")
      color.members.should eq(["red", "green", "blue"])
      color.fields.should be_empty
    end

    it "captures an enum reached through a return and through a NamedTuple member" do
      Palette.vow_types.map(&.crystal_name).should contain("Color")
    end

    it "reflects a custom Enum#to_json into the captured union" do
      hue = Palette.vow_types.find { |t| t.crystal_name == "Hue" }.not_nil!
      hue.members.should eq(["WARM", "COOL"])
    end

    it "captures an enum reached only through a struct field and an Array element" do
      weight = Palette.vow_types.find { |t| t.crystal_name == "Weight" }.not_nil!
      weight.kind.should eq("enum")
      weight.members.should eq(["light", "bold"])
    end

    it "round-trips an enum descriptor through JSON" do
      restored = Vow::Manifest.from_json(Vow::Registry.new(Palette.new).manifest.to_json)
      color = restored.types.find { |t| t.crystal_name == "Color" }.not_nil!
      color.kind.should eq("enum")
      color.members.should eq(["red", "green", "blue"])
    end

    it "emits an enum as a TS string-literal union type alias from its serialized values" do
      ts = Vow::Codegen::TypeScript.emit(Vow::Registry.new(Palette.new).manifest)
      ts.should contain(%(export type Color = "red" | "green" | "blue";))
      ts.should contain(%(export type Hue = "WARM" | "COOL";))
      ts.should contain("pick(args: { name: string }): Promise<Color>")
    end

    it "declares the same enum alias (not an interface) in the .d.ts" do
      dts = Vow::Codegen::TypeScript.emit_dts(Vow::Registry.new(Palette.new).manifest)
      dts.should contain(%(export type Color = "red" | "green" | "blue";))
      dts.should_not contain("export interface Color")
    end
  end
end
