require "argy"
require "../vow"

module Vow
  module CLI
    module Version
      def self.command : Argy::Command
        cmd = Argy::Command.new(use: "version", short: "Print the Vow version")
        cmd.on_run { |_c, _args| puts ::Vow::VERSION }
        cmd
      end
    end
  end
end
