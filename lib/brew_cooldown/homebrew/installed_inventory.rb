# frozen_string_literal: true

require "formula"
require "keg"
require "tab"
require "cask/caskroom"
require "cask/tab"
require_relative "../planner"
require_relative "../../../prototype/compatibility"
require_relative "../../../prototype/inventory"
require_relative "../../../prototype/cask_retained"

module BrewCooldown
  module HomebrewAdapter
    InstalledRecord = Data.define(:installed, :dependencies, :compatibility_version, :retained, :receipt, :identity)
    InventoryResult = Data.define(:records, :errors, :fingerprint)

    module InstalledInventory
      def self.package(name, kind: :formula, default_tap: "homebrew/core")
        unless name.is_a?(String) && name.match?(/\A(?:[a-z0-9_-]+\/[a-z0-9_-]+\/)?[a-z0-9][a-z0-9+@._-]*\z/) && !name.include?("..")
          raise ArgumentError, "Invalid package identity: #{name}"
        end
        pieces = name.split("/")
        case pieces.length
        when 1 then PackageId.new(kind:, tap: default_tap, name:)
        when 3 then PackageId.new(kind:, tap: pieces.first(2).join("/"), name: pieces.last)
        else raise ArgumentError, "Invalid package identity: #{name}"
        end
      end

      def self.requirements(rows)
        raise ArgumentError, "Missing installed runtime dependencies" unless rows.is_a?(Array)

        rows.map do |row|
          raise ArgumentError, "Runtime dependency must be an object" unless row.is_a?(Hash)

          name = row.fetch("full_name")
          version = row.fetch("pkg_version")
          raise ArgumentError, "Invalid runtime dependency identity" unless name.is_a?(String) && version.is_a?(String) && !version.empty?

          pkg = PkgVersion.parse(version)
          rebuild = row["bottle_rebuild"]
          cohort = row["compatibility_version"]
          raise ArgumentError, "Invalid recorded bottle rebuild" unless rebuild.nil? || (rebuild.is_a?(Integer) && rebuild >= 0)
          raise ArgumentError, "Invalid compatibility identifier" unless cohort.nil? || cohort.is_a?(Integer)

          # Older receipts can omit rebuild identity. Leaving it unknown avoids
          # claiming an exact build match against a replacement bottle.
          build = Build.new(version: pkg.version.to_s, revision: pkg.revision, rebuild:, scheme: nil)
          Requirement.new(package: package(name), build:, compatibility_version: cohort)
        end
      end

      def self.capture(log:)
        records = {}
        errors = []
        Formula.racks.sort.each do |rack|
          name = rack.basename.to_s
          begin
            record = formula(rack)
            records[record.installed.package] = record
          rescue StandardError => error
            details = { operation: "read_installed_formula", package: name, error: error.message,
                        error_class: error.class.name, backtrace: error.backtrace,
                        recovery: Prototype::Recovery.commands(name) }
            errors << details
            log.call(**details)
          end
        end
        Cask::Caskroom.tokens.sort.each do |name|
          begin
            record = cask(name)
            records[record.installed.package] = record
          rescue StandardError => error
            details = { operation: "read_installed_cask", package: name, error: error.message,
                        error_class: error.class.name, backtrace: error.backtrace,
                        recovery: Prototype::Recovery.commands(name, kind: "cask") }
            errors << details
            log.call(**details)
          end
        end
        fingerprint = Prototype::Inventory.capture
        InventoryResult.new(records: records.freeze, errors: errors.freeze, fingerprint: fingerprint.sort.to_h.freeze)
      end

      def self.formula(rack)
        name = rack.basename.to_s
        opt = HOMEBREW_PREFIX/"opt"/name
        raise ArgumentError, "#{name}: no active opt link; inspect retained kegs before choosing a baseline" unless opt.symlink? && opt.exist?

        active_path = opt.realpath
        keg = Keg.new(active_path)
        raise ArgumentError, "#{name}: active link points outside its rack" unless active_path.parent == rack.realpath

        linked = HOMEBREW_LINKED_KEGS/name
        raise ArgumentError, "#{name}: linked and opt kegs disagree" if linked.symlink? && (!linked.exist? || linked.realpath != active_path)

        receipt = keg/"INSTALL_RECEIPT.json"
        raise ArgumentError, "#{name}: installed receipt is missing" unless receipt.file?

        tab = Tab.for_keg(keg)
        tap = tab.tap&.name
        raise ArgumentError, "#{name}: receipt has no tap identity" unless tap

        identity = package("#{tap}/#{name}")
        retained = Prototype::Retained.new(keg) if tap == "homebrew/core"
        # The embedded source recipe can omit its bottle block, or describe an
        # earlier bottle. Its default rebuild zero is not installed identity.
        build = Build.new(version: keg.version.version.to_s, revision: keg.version.revision,
                          rebuild: nil, scheme: keg.version_scheme)
        installed = Installed.new(package: identity, build:, pinned: (HOMEBREW_PINNED_KEGS/name).symlink?)
        InstalledRecord.new(installed:, dependencies: requirements(tab.runtime_dependencies),
                            compatibility_version: retained&.compatibility_version, retained:, receipt: receipt.to_s,
                            identity: Digest::SHA256.hexdigest([receipt.read, retained&.worker_record&.fetch("recipe_sha256")].join("\n")))
      end

      def self.cask(name)
        receipt = Cask::Caskroom.path/name/".metadata/INSTALL_RECEIPT.json"
        raise ArgumentError, "#{name}: installed cask receipt is missing" unless receipt.file?

        tab = Cask::Tab.from_file(receipt)
        tap = tab.source["tap"]
        version = tab.version
        raise ArgumentError, "#{name}: cask receipt has no tap or version" unless tap.is_a?(String) && version.is_a?(String)
        runtime = tab.runtime_dependencies
        raise ArgumentError, "#{name}: cask dependency evidence is missing" unless runtime.is_a?(Hash)

        identity = package("#{tap}/#{name}", kind: :cask)
        build = Build.new(version:, revision: 0, rebuild: 0, scheme: 0)
        retained = Prototype::CaskRetained.new(name)
        installed = Installed.new(package: identity, build:, pinned: retained.cask.pinned?)
        InstalledRecord.new(installed:, dependencies: cask_requirements(runtime),
                            compatibility_version: nil, retained:, receipt: receipt.to_s,
                            identity: Digest::SHA256.file(receipt).hexdigest)
      end

      def self.cask_requirements(runtime)
        raise ArgumentError, "Missing cask runtime dependency evidence" unless runtime.is_a?(Hash)

        { "formula" => :formula, "cask" => :cask }.flat_map do |field, kind|
          rows = runtime.fetch(field, [])
          raise ArgumentError, "Invalid cask #{field} requirements" unless rows.is_a?(Array)

          rows.map do |row|
            raise ArgumentError, "Invalid cask dependency record" unless row.is_a?(Hash) && row["full_name"].is_a?(String)

            identity = package(row.fetch("full_name"), kind:, default_tap: kind == :cask ? "homebrew/cask" : "homebrew/core")
            RuntimeRequirement.new(package: identity)
          end
        end
      end
    end
  end
end
