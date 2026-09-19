# frozen_string_literal: true

require_relative "../../lib/brew_cooldown/homebrew/current_formula"

adapter = BrewCooldown::HomebrewAdapter::CurrentFormula
current = { "name" => "pcre2", "tap" => "homebrew/core", "version_scheme" => 0, "disabled" => false,
            "versions" => { "stable" => "10.48" }, "revision" => 0, "bottle" => { "stable" => { "rebuild" => 0 } } }
raise "Enabled core identity rejected" unless adapter.validate(current, name: "pcre2") == current

# A valid old bottle cannot bypass a current provider withdrawal.
[
  current.merge("disabled" => true, "disable_reason" => "upstream security withdrawal"),
  current.reject { |key, _| key == "disabled" },
  current.merge("name" => "other"),
  current.merge("tap" => "other/tap"),
  current.merge("version_scheme" => -1),
].each do |data|
  begin
    adapter.validate(data, name: "pcre2")
  rescue BrewCooldown::HomebrewAdapter::RegistryError => error
    if data["disabled"] == true && !error.message.include?("upstream security withdrawal")
      raise "Withdrawal reason missing"
    end
    next
  end
  raise "Invalid or withdrawn identity accepted: #{data.inspect}"
end
# A registry can retain the artifacts of a version Homebrew has rolled back.
# Its age and availability must not authorize a build ahead of current source.
build = BrewCooldown::Build.new(version: "10.48", revision: 0, rebuild: 0, scheme: 0)
adapter.verify_candidate!(current, build)
adapter.verify_candidate!(current, build.with(version: "10.47"))
adapter.verify_candidate!(current.merge("version_scheme" => 1), build.with(version: "99.0"))
[build.with(version: "10.49"), build.with(revision: 1), build.with(rebuild: 1), build.with(scheme: 1)].each do |candidate|
  begin
    adapter.verify_candidate!(current, candidate)
  rescue BrewCooldown::HomebrewAdapter::RegistryError
    next
  end
  raise "Candidate ahead of current Homebrew source was accepted"
end
puts "PASS: current formula identity and withdrawal"
