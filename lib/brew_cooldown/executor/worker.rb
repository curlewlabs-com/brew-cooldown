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

  FORMULAE = JSON.parse(source).each_with_object({}) do |record, result|
    recipe = record.fetch("recipe")
    unless Digest::SHA256.hexdigest(recipe) == record.fetch("recipe_sha256")
      raise Refused, "post-install recipe changed"
    end

    name = record.fetch("name")
    path = Pathname(record.fetch("path"))
    formula = Formulary.from_contents(name, path, recipe, tap: CoreTap.instance, from_metadata: true)
    unless formula.full_name == name && formula.pkg_version.to_s == record.fetch("version")
      raise Refused, "post-install identity changed"
    end

    [name, "homebrew/core/#{name}", path.to_s].each { |key| result[key] = formula }
  end.freeze

  module Resolver
    def factory(reference, spec = :stable, alias_path: nil, from: nil,
                warn: false, force_bottle: false, flags: [], ignore_errors: false)
      unless spec == :stable && alias_path.nil? && [nil, :rack, :keg].include?(from) &&
             !force_bottle && flags.empty? && !ignore_errors
        raise Refused, "unplanned post-install recipe options"
      end

      FORMULAE.fetch(reference.to_s) { raise Refused, "unplanned post-install lookup: #{reference}" }
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
