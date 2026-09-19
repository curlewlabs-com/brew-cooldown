# frozen_string_literal: true

require "stringio"
require "json"
require_relative "../../lib/brew_cooldown/report"
require_relative "../../lib/brew_cooldown/policy"
require_relative "../../prototype/inventory"

# A drift report groups recovery by package, unlike a candidate's flat list.
# Both must expose the commands and their consequences to a terminal operator.
recoveries = BrewCooldown::Prototype::Recovery.commands("pcre2")
[recoveries, { "pcre2" => recoveries }].each do |recovery|
  result = { status: "incomplete", scope: [], components: [], candidates: [], installed_security: [],
             errors: [{ error: "Installed state changed", recovery: }] }
  output = StringIO.new
  BrewCooldown::Report.print_human(result, output)
  recoveries.each do |entry|
    raise "Recovery command missing" unless output.string.include?(entry.fetch("command"))
    raise "Recovery consequence missing" unless output.string.include?(entry.fetch("purpose"))
  end
end

# A mature root can remain installed because a shared consumer constrains it.
# Its explanation must survive the human projection of a successful assessment.
conflict = "outside consumer requires library compatible with 1.0.0"
output = StringIO.new
BrewCooldown::Report.print_human({ status: "assessed", scope: [], errors: [],
  components: [{ selected: [], rejected_options: { "candidate" => conflict } }],
  candidates: [{ identity: "candidate", package: { name: "app" }, build: { version: "2.0.0" },
                 decision: { status: :eligible } }],
  installed_security: [{ package: { name: "app" }, coverage: :no_records }] }, output)
raise "Dependency conflict hidden" unless output.string.include?("app 2.0.0: #{conflict}")
raise "Unknown security coverage hidden" unless output.string.include?("app: no_records")

package = BrewCooldown::PackageId.new(kind: :formula, tap: "homebrew/core", name: "pcre2")
instant = Time.iso8601("2026-09-18T23:45:00-07:00")
value = BrewCooldown::Report.json_value({ errors: [{ package:, boundary: instant }] })
decoded = JSON.parse(JSON.generate(value)).fetch("errors").first
raise "Package identity rendered as opaque text" unless decoded.fetch("package").fetch("name") == "pcre2"
raise "Timestamp did not preserve its UTC instant" unless decoded.fetch("boundary") == "2026-09-19T06:45:00.000000000Z"
puts "PASS: recovery commands, consequences and structured identities"
