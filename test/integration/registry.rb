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
[
  ["lz4", "1.10.0"], ["libyaml", "0.2.5"], ["libxcb", "1.17.0"], ["lzo", "2.10"],
].each do |name, tag|
  historical = registry.resolve(name, tag)
  raise "Historical identity changed" unless historical.name == name && historical.pkg_version == tag
  puts JSON.pretty_generate(historical.to_h)
end
puts "PASS: live paginated core history and immutable platform metadata (no package changes)"
