require "argy"
require "../vow"
require "./gen"
require "./version"

module Vow
  module CLI
    # Builds the `vow` command tree. Kept separate from the binary entrypoint
    # (`src/vow_cli.cr`) so it can be exercised in specs via `root.execute(argv)`.
    def self.root : Argy::Command
      root = Argy::Command.new(use: "vow", short: "Vow — annotate methods, generate typed clients")
      root.add_command(Gen.command, Version.command)
      root
    end
  end
end
