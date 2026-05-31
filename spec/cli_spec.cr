require "./spec_helper"
require "../src/vow_cli/root"

# A service owned by this file, so the discovery specs below don't lean on a
# class defined elsewhere — `Vow.discovered_manifest` is global compile-time
# discovery, so a class declared here is found whether the whole suite compiles
# together or this file runs on its own. (Same pattern as exportable_all_spec.)
class CliProbe
  include Vow::Exportable

  @[Vow::Export]
  def greet(name : String) : String
    "Hi #{name}"
  end

  @[Vow::Export(name: "cliProbe.renamed")] # honored verbatim, like any override
  def tally : Int32
    42
  end

  # Unannotated under plain `Vow::Exportable` — must never reach the manifest.
  def secret : String
    "nope"
  end
end

describe "vow CLI" do
  describe "gen --manifest" do
    it "drives the CLI to write a TS client from a manifest file" do
      manifest = %({"procedures":[{"name":"API.ping","args":[],"return_type":"String"}],"types":[]})
      mpath = File.tempname("vow", ".json")
      opath = File.tempname("vow", ".ts")
      File.write(mpath, manifest)
      begin
        # Capture the CLI's stderr (argy 0.4 stream injection) so the status
        # line is asserted on, not leaked into the spec output.
        root = Vow::CLI.root
        status = IO::Memory.new
        root.stderr = status
        root.execute(["gen", "--manifest", mpath, "--out", opath])

        out = File.read(opath)
        out.should contain("export function createClient(transport: VowTransport)")
        out.should contain("ping(args: {} = {}): Promise<string> { return transport(\"API.ping\", args, \"post\") as Promise<string>; },")
        status.to_s.should contain("wrote 1 procedure(s), 0 type(s)")
      ensure
        File.delete(mpath) if File.exists?(mpath)
        File.delete(opath) if File.exists?(opath)
      end
    end
  end

  describe "gen --target js" do
    it "writes a .js runtime and a .d.ts beside it from one --out stem" do
      manifest = %({"procedures":[{"name":"API.ping","args":[],"return_type":"String"}],"types":[]})
      mpath = File.tempname("vow", ".json")
      stem = File.tempname("vowclient", "")
      File.write(mpath, manifest)
      begin
        root = Vow::CLI.root
        root.stderr = IO::Memory.new
        # --out is a stem (no extension); the js target appends .js and .d.ts.
        root.execute(["gen", "--manifest", mpath, "--target", "js", "--out", stem])

        js = File.read("#{stem}.js")
        js.should contain("export function createClient(transport) {")
        js.should contain("ping(args = {}) { return transport(\"API.ping\", args, \"post\"); },")
        js.should_not contain(": Promise") # runtime carries no type annotations

        dts = File.read("#{stem}.d.ts")
        dts.should contain("export declare function createClient(transport: VowTransport): {")
        dts.should contain("ping(args?: {}): Promise<string>;")
      ensure
        File.delete(mpath) if File.exists?(mpath)
        File.delete("#{stem}.js") if File.exists?("#{stem}.js")
        File.delete("#{stem}.d.ts") if File.exists?("#{stem}.d.ts")
      end
    end
  end

  describe "gen --check" do
    it "passes (writes nothing) when the client on disk is current" do
      manifest = %({"procedures":[{"name":"API.ping","args":[],"return_type":"String"}],"types":[]})
      mpath = File.tempname("vow", ".json")
      opath = File.tempname("vow", ".ts")
      File.write(mpath, manifest)
      begin
        # Generate the client once …
        write = Vow::CLI.root
        write.stderr = IO::Memory.new
        write.execute(["gen", "--manifest", mpath, "--out", opath])
        before = File.info(opath).modification_time

        # … then --check it: status says "up to date" and the file is untouched.
        check = Vow::CLI.root
        status = IO::Memory.new
        check.stderr = status
        check.execute(["gen", "--manifest", mpath, "--out", opath, "--check"])

        status.to_s.should contain("client is up to date")
        File.info(opath).modification_time.should eq(before) # nothing written
      ensure
        File.delete(mpath) if File.exists?(mpath)
        File.delete(opath) if File.exists?(opath)
      end
    end

    # Stale-client path exits non-zero, so drive the real binary in a subprocess
    # (the in-process `abort` would kill the spec run) — same pattern as the
    # "fails loud" entry test below.
    it "fails non-zero, naming the stale file, when the client is out of date" do
      manifest = %({"procedures":[{"name":"API.ping","args":[],"return_type":"String"}],"types":[]})
      mpath = File.tempname("vow", ".json")
      opath = File.tempname("vow", ".ts")
      File.write(mpath, manifest)
      File.write(opath, "// stale — does not match the manifest\n")
      begin
        captured = IO::Memory.new
        errors = IO::Memory.new
        status = Process.run("crystal", ["run", "--no-color", "src/vow_cli.cr", "--", "gen", "--manifest", mpath, "--out", opath, "--check"], output: captured, error: errors)
        status.success?.should be_false
        errors.to_s.should contain("out of date")
        errors.to_s.should contain(opath) # the offending path is named
      ensure
        File.delete(mpath) if File.exists?(mpath)
        File.delete(opath) if File.exists?(opath)
      end
    end
  end

  # Static discovery is the heart of the zero-boilerplate design: the manifest
  # comes straight from the macro-captured descriptors — no instance, no
  # registry, no hand-written dump program.
  describe "Vow.discovered_manifest" do
    it "includes every @[Vow::Export] method and excludes unannotated ones" do
      names = Vow.discovered_manifest.procedures.map(&.name)
      names.should contain("CliProbe.greet")
      names.should contain("cliProbe.renamed")
      names.should_not contain("CliProbe.secret")
    end
  end

  describe "Vow.emit_manifest" do
    it "writes a framed manifest that round-trips and feeds the generator" do
      io = IO::Memory.new
      Vow.emit_manifest(io)
      dump = io.to_s

      dump.should contain(Vow::MANIFEST_BEGIN)
      dump.should contain(Vow::MANIFEST_END)

      b = dump.index(Vow::MANIFEST_BEGIN).not_nil! + Vow::MANIFEST_BEGIN.size
      e = dump.index(Vow::MANIFEST_END).not_nil!
      manifest = Vow::Manifest.from_json(dump[b...e].strip)
      manifest.procedures.map(&.name).should contain("CliProbe.greet")

      Vow::Codegen::TypeScript.emit(manifest).should contain("greet(args: { name: string }): Promise<string>")
    end
  end

  # End-to-end: the entry is what a user would actually write — `require` +
  # annotate, nothing else. Drives the real CLI command (compile+run the entry,
  # extract the framed manifest, emit, write the file), using a real repo file
  # resolved from the spec's working dir (the project root) so there is no
  # hand-built temp-file require path to get wrong.
  describe "gen --entry (zero boilerplate)" do
    it "generates a client straight from an annotated entry" do
      opath = File.tempname("vow", ".ts")
      begin
        root = Vow::CLI.root
        root.stderr = IO::Memory.new # capture the status line; keep spec output clean
        root.execute(["gen", "--entry", "examples/basic.cr", "--out", opath])
        File.read(opath).should contain("greet(args: { name: string }): Promise<string>")
      ensure
        File.delete(opath) if File.exists?(opath)
      end
    end

    it "fails loud when the entry exports nothing" do
      captured = IO::Memory.new
      errors = IO::Memory.new
      status = Process.run("crystal", ["run", "--no-color", "src/vow.cr", "--", Vow::MANIFEST_FLAG], output: captured, error: errors)
      status.success?.should be_false
      errors.to_s.should contain("no exported methods found")
    end
  end
end
