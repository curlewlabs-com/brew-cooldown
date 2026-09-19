# frozen_string_literal: true

require "json"
require_relative "../../lib/brew_cooldown/homebrew/current_formula"

log = ->(**event) { warn JSON.generate(event) }
adapter = BrewCooldown::HomebrewAdapter::CurrentFormula
absent = "brew-cooldown-no-such-formula"
# The recorded unit fixtures cannot show that curl's parallel transfer reports
# one status per destination, or that a missing formula leaves the others
# intact. Only the real service and the real curl can.
results = adapter.fetch_all(["pcre2", "ruby@3.3", absent], log:)
%w[pcre2 ruby@3.3].each do |name|
  current = results.fetch(name)
  raise "Live batched read failed for #{name}: #{current.inspect}" unless current.is_a?(Hash) && current.fetch("name") == name
  raise "Batched and single reads disagree for #{name}" unless current == adapter.fetch(name, log:)
end
missing = results.fetch(absent)
raise "A missing formula was not reported on its own: #{missing.inspect}" unless
  missing.is_a?(BrewCooldown::HomebrewAdapter::RegistryError) && missing.message.include?("HTTP 404")
puts "PASS: live batched current-formula reads with an isolated missing formula (no package changes)"
