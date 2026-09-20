# frozen_string_literal: true

require "stringio"
require "json"
require_relative "../../lib/brew_cooldown/report"
require_relative "../../lib/brew_cooldown/policy"
require_relative "../../lib/brew_cooldown/executor/inventory"

# A drift report groups recovery by package, unlike a candidate's flat list.
# Both must expose the commands and their consequences to a terminal operator.
recoveries = BrewCooldown::Executor::Recovery.commands("pcre2")
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

# Security-only execution may intentionally skip an eligible routine upgrade.
# Terminal output must not present the proposal as an executed operation.
output = StringIO.new
BrewCooldown::Report.print_upgrade({ status: "completed", scope: [], errors: [], candidates: [], installed_security: [], execution: [],
  components: [{ rejected_options: {}, selected: [{ operation: "upgrade", package: { name: "app" },
    build: { version: "2.0.0", revision: 0, rebuild: 0 }, decision: { reason: "Mature release" } }] }] }, output)
raise "Unexecuted proposal presented as an upgrade" if output.string.include?("Upgrade app")

# A component borrows the journal's operation layout. A completed upgrade must
# not be announced as a recovery, which would send the operator looking for an
# interruption that never happened.
output = StringIO.new
BrewCooldown::Report.print_upgrade({ status: "completed", execution: [
  { "status" => "completed", "operations" => [{ "kind" => "formula", "name" => "app", "version" => "2.0.0", "status" => "completed" }] }
] }, output)
raise "Completed operation hidden" unless output.string.include?("Component: completed") &&
  output.string.include?("formula/app 2.0.0: completed")
raise "Completed upgrade presented as recovery" if output.string.match?(/recover/i)

# A native pre-install drift result must expose the changed path as well as
# repair commands, before an unfinished journal exists.
output = StringIO.new
BrewCooldown::Report.print_recovery({ status: "drift", changes: [{ "path" => "/opt/homebrew/opt/app",
  "expected" => "../Cellar/app/1.0", "observed" => "../Cellar/app/2.0" }] }, output)
raise "Pre-install drift details hidden" unless output.string.include?("Changed /opt/homebrew/opt/app") &&
  output.string.include?("../Cellar/app/2.0")

# A failed cask and a formula may share a token. Terminal recovery must retain
# the kind and cask baseline rather than suggesting the wrong repair target.
output = StringIO.new
cask_recovery = BrewCooldown::Executor::Recovery.commands("shared-token", kind: "cask")
BrewCooldown::Report.print_recovery({ status: "needs_reconciliation", operations: [
  { "kind" => "cask", "name" => "shared-token", "version" => "2.0", "previous_version" => "1.0",
    "status" => "failed", "recovery" => cask_recovery }
] }, output)
raise "Cask recovery identity hidden" unless output.string.include?("cask/shared-token 2.0: failed") &&
  output.string.include?("Previous version: 1.0") && output.string.include?("reinstall --cask shared-token")

# An already installed version can have unknown bottle bytes without becoming
# an upgrade failure. Keep its uncertainty and manual repair consequences visible.
output = StringIO.new
BrewCooldown::Report.print_human({ status: "assessed", scope: [], components: [], candidates: [], installed_security: [], errors: [],
  diagnostics: [{ reason: "Installed bottle rebuild is unknown", recovery: recoveries }] }, output)
raise "Native identity diagnostic was hidden or presented as failure" unless output.string.include?("Note: Installed bottle rebuild is unknown") &&
  output.string.include?("outside the cooldown policy") && !output.string.include?("Error:")

# A prefix installed from Homebrew's API reports an unknown bottle rebuild for
# every package sitting on a version Homebrew has since rebuilt, and those
# entries differ only in the package name. Printing each in full outnumbered
# the rest of the report, so several collapse to one line naming all of them.
rebuilds = %w[taplo actionlint shellcheck].map do |name|
  { operation: "inspect_installed_artifact", status: "unknown_installed_build",
    package: { kind: :formula, tap: "homebrew/core", name: },
    reason: "#{name}: no rebuild-only replacement is selected",
    recovery: BrewCooldown::Executor::Recovery.commands(name) }
end
plain = { status: "assessed", scope: [], components: [], candidates: [], installed_security: [], errors: [] }
output = StringIO.new
BrewCooldown::Report.print_human(plain.merge(diagnostics: rebuilds), output)
raise "Collapsed summary dropped a package" unless output.string.include?("actionlint, shellcheck, taplo")
raise "Collapsed summary kept a per-package repair block" if output.string.include?("reinstall --formula taplo")
raise "Collapsed summary lost the route to per-package detail" unless output.string.include?("brew-cooldown explain actionlint")
raise "Collapsed summary presented as failure" if output.string.include?("Error:")

# `explain PACKAGE` narrows these diagnostics to one package, which is exactly
# where an operator wants the repair commands. A lone entry must keep them.
output = StringIO.new
BrewCooldown::Report.print_human(plain.merge(diagnostics: [rebuilds.first]), output)
raise "Single diagnostic lost its repair commands" unless output.string.include?("reinstall --formula taplo")
raise "Single diagnostic was collapsed" if output.string.include?("brew-cooldown explain")

# Diagnostics from other operations carry no rebuild status and must survive a
# collapse happening beside them.
advisory = { operation: "read_cached_advisories", reason: "Advisory feed was not validated in this run" }
output = StringIO.new
BrewCooldown::Report.print_human(plain.merge(diagnostics: rebuilds + [advisory]), output)
raise "Unrelated diagnostic was collapsed away" unless output.string.include?("Note: Advisory feed was not validated in this run")
raise "Collapsed summary missing beside an unrelated diagnostic" unless output.string.include?("actionlint, shellcheck, taplo")

# A summary stands for the packages it names. If an entry carries no package
# identity the summary would silently speak for less than it replaced, so the
# entries keep their individual notes and commands instead.
output = StringIO.new
anonymous = { operation: "inspect_installed_artifact", status: "unknown_installed_build",
              reason: "an entry without package identity", recovery: recoveries }
BrewCooldown::Report.print_human(plain.merge(diagnostics: [rebuilds.first, anonymous]), output)
raise "Unnameable entry was collapsed into a summary" if output.string.include?("brew-cooldown explain")
raise "Unnameable entry lost its own note" unless output.string.include?("Note: an entry without package identity") &&
  output.string.include?("reinstall --formula taplo")

package = BrewCooldown::PackageId.new(kind: :formula, tap: "homebrew/core", name: "pcre2")
instant = Time.iso8601("2026-09-18T23:45:00-07:00")
value = BrewCooldown::Report.json_value({ errors: [{ package:, boundary: instant }] })
decoded = JSON.parse(JSON.generate(value)).fetch("errors").first
raise "Package identity rendered as opaque text" unless decoded.fetch("package").fetch("name") == "pcre2"
raise "Timestamp did not preserve its UTC instant" unless decoded.fetch("boundary") == "2026-09-19T06:45:00.000000000Z"
puts "PASS: recovery commands, consequences and structured identities"
