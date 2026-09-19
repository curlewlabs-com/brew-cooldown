# frozen_string_literal: true

require_relative "../../lib/brew_cooldown/homebrew/current_formula"

adapter = BrewCooldown::HomebrewAdapter::CurrentFormula
current = { "name" => "pcre2", "tap" => "homebrew/core", "version_scheme" => 0, "disabled" => false }
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
puts "PASS: current formula identity and withdrawal"
