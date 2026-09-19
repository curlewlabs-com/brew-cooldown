# frozen_string_literal: true

require_relative "../../lib/brew_cooldown/homebrew/registry"

log = ->(**event) { warn JSON.generate(event) }
registry = BrewCooldown::HomebrewAdapter::Registry.new(
  transport: BrewCooldown::HomebrewAdapter::RegistryTransport.new(log:),
)
# A small page size exercises the real next-link path, including its terminal
# response, rather than assuming a single page constitutes the whole history.
tags = registry.tags("pcre2", page_size: 5)
raise "Historical tag missing" unless tags.include?("10.47")
metadata = registry.resolve("pcre2", "10.47", platform: :arm64_tahoe)
raise "Historical publication missing" unless metadata.published_at
puts JSON.pretty_generate(metadata.to_h)
versioned = registry.resolve("ruby@3.3", "3.3.12", platform: :arm64_tahoe)
raise "Versioned formula identity changed" unless versioned.name == "ruby@3.3"
puts "PASS: live paginated core history and immutable platform metadata (no package changes)"
