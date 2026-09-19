# frozen_string_literal: true

require "digest"
require "shellwords"
require "cask/caskroom"

module BrewCooldown
  module Prototype
    class Inventory
      def self.capture
        files = HOMEBREW_CELLAR.glob("*/*/INSTALL_RECEIPT.json") + HOMEBREW_CELLAR.glob("*/*/.brew/*.rb")
        state = files.to_h { |path| [path.to_s, Digest::SHA256.file(path).hexdigest] }
        [HOMEBREW_PREFIX/"opt", HOMEBREW_PINNED_KEGS, HOMEBREW_LINKED_KEGS].each do |directory|
          next unless directory.directory?

          directory.children.select(&:symlink?).each { |path| state[path.to_s] = path.readlink.to_s }
        end
        Cask::Caskroom.path.glob("*/.metadata/**/{INSTALL_RECEIPT.json,*.rb,*.json}").sort.each do |path|
          state[path.to_s] = Digest::SHA256.file(path).hexdigest if path.file?
        end
        state.sort.to_h
      end

      def self.differences(before, after)
        (before.keys | after.keys).sort.filter_map do |path|
          { "path" => path, "expected" => before[path], "observed" => after[path] } if before[path] != after[path]
        end
      end
    end

    module Recovery
      def self.commands(name, previous_keg: nil, keg_only: false)
        brew = HOMEBREW_BREW_FILE.to_s
        commands = [
          { "purpose" => "Inspect installed versions", "command" => Shellwords.join([brew, "list", "--versions", name]) },
          { "purpose" => "Inspect package details and pin state", "command" => Shellwords.join([brew, "info", "--json=v2", name]) }
        ]
        if previous_keg && Pathname(previous_keg).directory?
          method = keg_only ? "optlink" : "link"
          code = "require 'keg'; Keg.new(Pathname(#{previous_keg.to_s.dump})).#{method}"
          commands << {
            "purpose" => "Restore retained keg links; does not undo post-install configuration changes",
            "command" => Shellwords.join([brew, "unlink", "--formula", name]) + " && " +
                         Shellwords.join([brew, "ruby", "-e", code])
          }
        end
        commands << {
          "purpose" => "Repair forward with Homebrew's current release, outside the cooldown policy",
          "command" => Shellwords.join([brew, "reinstall", "--formula", name])
        }
        commands
      end
    end
  end
end
