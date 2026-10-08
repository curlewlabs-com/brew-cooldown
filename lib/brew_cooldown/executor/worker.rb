# frozen_string_literal: true

require "global"
require "formula_installer"
require "digest"

module BrewCooldownWorker
  class Refused < StandardError; end

  source = File.binread(ENV.fetch("HOMEBREW_COOLDOWN_WORKER_PLAN"))
  unless Digest::SHA256.hexdigest(source) == ENV.fetch("HOMEBREW_COOLDOWN_WORKER_DIGEST")
    raise Refused, "post-install recipe map changed"
  end

  records = JSON.parse(source)
  RELEASE_ARCHIVES = records.select { |record| record["release_archive"] }.map { |record| record.fetch("name") }.freeze
  FORMULAE = records.each_with_object({}) do |record, result|
    recipe = record.fetch("recipe")
    unless Digest::SHA256.hexdigest(recipe) == record.fetch("recipe_sha256")
      raise Refused, "post-install recipe changed"
    end

    name = record.fetch("name")
    path = Pathname(record.fetch("path"))
    tap = record.fetch("tap", "homebrew/core")
    token = name.split("/").last
    formula = Formulary.from_contents(token, path, recipe, tap: Tap.fetch(tap), from_metadata: true)
    commit = record["commit"]
    formula.define_singleton_method(:tap_git_head) { commit } if commit
    unless formula.full_name == name && formula.pkg_version.to_s == record.fetch("version")
      raise Refused, "post-install identity changed"
    end

    if record["release_archive"]
      archive = Pathname(record.fetch("archive_path"))
      stage = Pathname(ENV.fetch("HOMEBREW_COOLDOWN_WORKER_PLAN")).dirname
      unless archive.dirname == stage && archive.file? && !archive.symlink? &&
             formula.resource.checksum.hexdigest == record.fetch("archive_sha256")
        raise Refused, "release archive snapshot identity changed"
      end
      resource = formula.resource
      resource.verify_download_integrity(archive)
      resource.downloader.define_singleton_method(:cached_location) { archive }
      resource.downloader.define_singleton_method(:fetch) { |timeout: nil| resource.verify_download_integrity(archive) }
    end

    keys = [name, path.to_s, (HOMEBREW_CELLAR/token/formula.pkg_version.to_s/".brew/#{token}.rb").to_s]
    keys << "homebrew/core/#{name}" if tap == "homebrew/core"
    keys.each { |key| result[key] = formula }
  end.freeze

  module Resolver
    def factory(reference, spec = :stable, alias_path: nil, from: nil,
                warn: false, force_bottle: false, flags: [], ignore_errors: false)
      unless spec == :stable && alias_path.nil? && [nil, :rack, :keg].include?(from) &&
             !force_bottle && !ignore_errors
        raise Refused, "unplanned post-install recipe options"
      end

      formula = FORMULAE.fetch(reference.to_s) { raise Refused, "unplanned post-install lookup: #{reference}" }
      unless flags.empty? || (flags == ["--build-from-source"] && RELEASE_ARCHIVES.include?(formula.full_name))
        raise Refused, "unplanned recipe flags: #{reference}"
      end
      formula
    end
  end

  module NoInstaller
    def initialize(*)
      raise Refused, "package installation from a post-install hook is forbidden"
    end
  end
end

Formulary.singleton_class.prepend(BrewCooldownWorker::Resolver)
FormulaInstaller.prepend(BrewCooldownWorker::NoInstaller)
