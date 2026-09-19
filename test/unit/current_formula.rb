# frozen_string_literal: true

require "json"
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
# With Homebrew's current version and revision installed, nothing in the
# registry can advance the package. Anything less than equality must still be
# examined: a revision, a scheme change or a newer release is an upgrade.
raise "Installed current build not recognized" unless adapter.installed?(current, build)
[build.with(version: "10.47"), build.with(revision: 1), build.with(scheme: 1), build.with(version: "10.49")].each do |installed|
  raise "A differing installation skipped discovery: #{installed}" if adapter.installed?(current, installed)
end
raise "Installed rebuild identity influenced the comparison" unless adapter.installed?(current, build.with(rebuild: nil))
raise "Absent rebuild metadata became a rebuild" unless adapter.rebuild(current.reject { |key, _| key == "bottle" }).zero?
raise "Published rebuild lost" unless adapter.rebuild(current.merge("bottle" => { "stable" => { "rebuild" => 3 } })) == 3

# The batched read replaces one process per formula. Each package keeps its
# own outcome: one withdrawn, missing or malformed response must neither fail
# the others nor be mistaken for an enabled formula.
events = []
log = ->(**event) { events << event }
bodies = {
  "pcre2" => ["200", JSON.generate(current)],
  "withdrawn" => ["200", JSON.generate(current.merge("name" => "withdrawn", "disabled" => true, "disable_reason" => "upstream security withdrawal"))],
  "impostor" => ["200", JSON.generate(current)],
  "missing" => ["404", "<html>not found</html>"],
  "garbled" => ["200", "{"],
  "silent" => [nil, nil],
}
requested = nil
transfer = lambda do |requests|
  requested = requests
  requests.to_h do |url, path|
    name = File.basename(path, ".json")
    raise "Unexpected destination #{url}" unless url == "https://formulae.brew.sh/api/formula/#{name}.json"

    status, body = bodies.fetch(name)
    File.write(path, body) if body
    [path, status]
  end.compact
end
results = adapter.fetch_all(bodies.keys + ["pcre2"], log:, transfer:)
raise "Repeated names were requested twice" unless requested.length == bodies.length
raise "Valid current metadata lost" unless results.fetch("pcre2") == current
{ "withdrawn" => "upstream security withdrawal", "impostor" => "identity", "missing" => "HTTP 404",
  "garbled" => "Invalid current formula JSON", "silent" => "no response" }.each do |name, fragment|
  outcome = results.fetch(name)
  raise "#{name} was accepted: #{outcome.inspect}" unless outcome.is_a?(BrewCooldown::HomebrewAdapter::RegistryError) &&
    outcome.message.include?(fragment)
end
raise "Batched read was not logged" unless events.any? { |event| event[:operation] == "read_current_formulae" && event[:packages] == bodies.length }
raise "Empty scope made a request" unless adapter.fetch_all([], log:, transfer: ->(_requests) { raise "requested" }).empty?
begin
  adapter.fetch_all(["../escape"], log:, transfer: ->(_requests) { raise "requested" })
rescue BrewCooldown::HomebrewAdapter::RegistryError => error
  raise unless error.message.include?("unqualified core formula")
  escaped = true
end
raise "A path-like name reached the request" unless escaped
puts "PASS: current formula identity, withdrawal, installed-current detection and batched reads"
