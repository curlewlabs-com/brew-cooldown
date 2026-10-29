# frozen_string_literal: true

require "digest"
require "shellwords"
require "cask/caskroom"

module BrewCooldown
  module Executor
    class Inventory
      def self.capture
        files = HOMEBREW_CELLAR.glob("*/*/INSTALL_RECEIPT.json") + HOMEBREW_CELLAR.glob("*/*/.brew/*.rb")
        state = files.to_h { |path| [path.to_s, Digest::SHA256.file(path).hexdigest] }
        [HOMEBREW_PREFIX/"opt", HOMEBREW_PINNED_KEGS, HOMEBREW_PINNED_CASKS, HOMEBREW_LINKED_KEGS,
         HOMEBREW_PREFIX/"bin", HOMEBREW_PREFIX/"sbin"].each do |directory|
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

      def self.command_link?(path)
        [HOMEBREW_PREFIX/"bin", HOMEBREW_PREFIX/"sbin"].any? { |directory| File.dirname(path) == directory.to_s }
      end

      def self.verify_commands!(keg)
        %w[bin sbin].each do |directory|
          root = keg/directory
          next unless root.directory?

          root.children.each do |source|
            next if source.basename.to_s == ".DS_Store" || source.directory?

            relative = source.relative_path_from(Pathname(keg))
            destination = HOMEBREW_PREFIX/relative
            resolved = Utils::Path.resolved_path(source)
            # Native linking skips links back into the prefix and split-package
            # links into another keg at the same relative path.
            next if resolved == destination || resolved.fnmatch?("#{HOMEBREW_PREFIX}/opt/*/#{relative}", File::FNM_PATHNAME)
            next if destination.symlink? && Utils::Path.resolved_path(destination) == source && destination.exist?

            raise Refused, "#{keg.name}: linked command missing or redirected: #{destination}"
          end
        end
      end
    end

    module Recovery
      def self.commands(name, previous_keg: nil, keg_only: false, kind: "formula")
        raise ArgumentError, "Unknown package kind: #{kind}" unless %w[formula cask].include?(kind)

        brew = HOMEBREW_BREW_FILE.to_s
        commands = [
          { "purpose" => "Inspect installed versions", "command" => Shellwords.join([brew, "list", "--#{kind}", "--versions", name]) },
          { "purpose" => "Inspect package details and pin state", "command" => Shellwords.join([brew, "info", "--#{kind}", "--json=v2", name]) }
        ]
        if kind == "formula" && previous_keg && Pathname(previous_keg).directory?
          method = keg_only ? "optlink" : "link"
          code = "require 'keg'; Keg.new(Pathname(#{previous_keg.to_s.dump})).#{method}"
          # From an ordinary shell, `brew ruby` would switch on the account's
          # persistent developer mode (see Execution.unqualified_checkout), and
          # the next `brew update` would leave the qualified release.
          commands << {
            "purpose" => "Restore retained keg links; does not undo post-install configuration changes",
            "command" => Shellwords.join([brew, "unlink", "--formula", name]) + " && " +
                         Shellwords.join(["env", "HOMEBREW_DEVELOPER=1", brew, "ruby", "-e", code])
          }
        end
        commands << {
          "purpose" => "Repair forward with Homebrew's current release, outside the cooldown policy",
          "command" => Shellwords.join([brew, "reinstall", "--#{kind}", name])
        }
        commands
      end
    end
  end
end
