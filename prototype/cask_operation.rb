# frozen_string_literal: true

require_relative "cask_map"

module BrewCooldown
  module Prototype
    # A native cask upgrade uses the installed predecessor's artifacts and
    # Homebrew's own failure restoration. Completion is read from native data.
    class CaskOperation
      attr_reader :candidate

      def initialize(candidate, predecessor: nil)
        @candidate, @predecessor = candidate, predecessor
      end

      def cask = candidate.cask
      def name = cask.token
      def kind = "cask"
      def key = [kind, cask.full_name]

      def dependencies
        cask.depends_on.formula.map { |entry| ["formula", entry.delete_prefix("homebrew/core/")] } +
          cask.depends_on.cask.map { |entry| [kind, entry.delete_prefix("homebrew/cask/")] }
      end

      def record
        verify_before!
        if @predecessor && Version.new(cask.version.to_s) <= Version.new(@predecessor.version.to_s)
          raise Refused, "#{name}: selected version does not advance the installed cask"
        end
        { "kind" => kind, "name" => name, "version" => cask.version.to_s,
          "previous_version" => @predecessor&.version&.to_s, "candidate" => candidate.record,
          "keg_only" => false, "status" => "pending" }
      end

      def verify_before! = candidate.verify!

      def install
        if @predecessor
          installer = Cask::Installer.new(cask, upgrade: true, require_sha: true)
          Cask::Upgrade.upgrade_cask(@predecessor, cask, binaries: true, force: false, require_sha: true,
                                    quit: false, skip_cask_deps: false, verbose: false,
                                    download_queue: Homebrew::DownloadQueue.default, new_cask_installer: installer)
        else
          Cask::Installer.new(cask, require_sha: true).install
        end
        raise Refused, "Homebrew reported failure for #{name}" if Homebrew.failed?

        # The native Tab cache is process-local. Completion requires the receipt
        # actually written to disk, including when another process did the work.
        path = cask.metadata_main_container_path/"INSTALL_RECEIPT.json"
        receipt = Cask::Tab.from_file_content(path.read, path)
        unless receipt.version == cask.version.to_s && receipt.tap&.name == "homebrew/cask" &&
               receipt.source.fetch("tap_git_head") == candidate.record.fetch("commit")
          raise Refused, "#{name}: installed cask receipt differs from the selected source"
        end
        cask.artifacts.each do |artifact|
          paths = case artifact
          when Cask::Artifact::Binary
            raise Refused, "#{name}: installed binary does not point to the selected cask: #{artifact.target}" unless artifact.target_links_to_source?

            [artifact.target]
          when Cask::Artifact::GeneratedCompletion
            # Homebrew owns completion naming and destinations. Its installer
            # only warns on generation failures, so verify those native paths.
            artifact.shells.map { |shell| artifact.send(:completion_script_path, shell) }
          else []
          end
          paths.each do |path|
            raise Refused, "#{name}: installed artifact is missing: #{path}" unless path.file? && path.size.positive?
          end
        end
      end

      def owns_path?(path) = path.start_with?("#{cask.caskroom_path}/")
    end
  end
end
