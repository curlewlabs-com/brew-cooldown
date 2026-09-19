# frozen_string_literal: true

module BrewCooldown
  # A focused view of a fresh plan. Matching stays inside the assessed scope,
  # including native aliases, so explanation never authorizes additional roots.
  module Explanation
    def self.call(result, requested:, installed:)
      matches = result.fetch(:scope).select do |entry|
        package = entry[:package]
        next false unless package

        [entry.fetch(:requested), package.fetch(:name), "#{package.fetch(:tap)}/#{package.fetch(:name)}",
         canonical(package)].include?(requested)
      end.map { |entry| entry.fetch(:package) }.uniq

      explanation = { requested:, matches: }
      case matches.length
      when 0
        explanation.merge!(status: :outside_scope, reason: "Package is not a declared root or an installed runtime dependency in this scope")
      when 1
        package = matches.first
        baseline = installed.find { |entry| entry.package.to_h == package }
        explanation.merge!(status: :matched, package:, installed: baseline&.to_h)
      else
        explanation.merge!(status: :ambiguous, reason: "Use a canonical identity: #{matches.map { |package| canonical(package) }.join(', ')}")
      end
      result.merge(command: "explain", status: matches.length > 1 ? "incomplete" : result.fetch(:status), explanation:)
    end

    def self.canonical(package)
      "#{package.fetch(:kind)}:#{package.fetch(:tap)}/#{package.fetch(:name)}"
    end
  end
end
