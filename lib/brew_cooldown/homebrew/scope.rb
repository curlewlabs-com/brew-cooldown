# frozen_string_literal: true

require "bundle/dsl"
require_relative "../config"

module BrewCooldown
  module HomebrewAdapter
    ScopeEntry = Data.define(:kind, :name, :options)

    module Scope
      def self.read(selection, installed:)
        if selection[:installed]
          return installed.map { |package| ScopeEntry.new(kind: package.kind, name: "#{package.tap}/#{package.name}", options: {}) }
        end

        path = selection.fetch(:brewfile)
        Homebrew::Bundle::Dsl.new(path).entries.map do |entry|
          kind = entry.type == :brew ? :formula : entry.type
          ScopeEntry.new(kind:, name: entry.options.fetch(:full_name, entry.name), options: entry.options)
        end
      rescue RuntimeError, SystemCallError => error
        raise ConfigurationError, "Cannot evaluate Brewfile #{path}: #{error.message}"
      end
    end
  end
end
