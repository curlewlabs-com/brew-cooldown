# frozen_string_literal: true

require "open3"
require "rbconfig"

abort "Run only in an expendable VM" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
require_relative "../../prototype/execution"
BrewCooldown::Prototype::Execution.check_homebrew!

phase = ARGV.fetch(0)
record = JSON.parse(File.read(File.join(__dir__, "interpreter_candidates.json"))).fetch(phase)
candidate = BrewCooldown::Prototype::Candidate.new(record).prepare(allow_hooks: true)
raise "Baseline requires ruby@3.3 absent" if phase == "baseline" && candidate.formula.opt_prefix.exist?
retained = candidate.runtime_dependencies.map do |dependency|
  path = HOMEBREW_PREFIX/"opt"/dependency.fetch("full_name")
  raise "Prepare installed dependency #{path}" unless path.exist?

  BrewCooldown::Prototype::Retained.new(Keg.new(path.realpath))
end
map = BrewCooldown::Prototype::ExactMap.new([candidate, *retained])
map.activate
inventory = BrewCooldown::Prototype::Inventory.capture

# A native sibling-link or dependency operation must fail at its mutation
# boundary, before a later inventory comparison could merely report damage.
begin
  BrewCooldown::Prototype.executing_name = candidate.formula.name
  begin
    retained.first.keg.unlink
    raise "Unplanned dependency unlink was allowed"
  rescue BrewCooldown::Prototype::Refused => error
    raise unless error.message.include?("unplanned unlink")
  end
  begin
    installer = FormulaInstaller.new(candidate.formula)
    installer.install_dependency(Dependency.new(retained.first.formula.name))
    raise "Implicit dependency installation was allowed"
  rescue BrewCooldown::Prototype::Refused => error
    raise unless error.message.include?("was not completed before installation")
  end
  raise "Guard probe changed inventory" unless inventory == BrewCooldown::Prototype::Inventory.capture
ensure
  BrewCooldown::Prototype.executing_name = nil
end

runtime_path = Pathname(RbConfig.ruby).realpath
raise "Tool is running from a formula-managed interpreter" if runtime_path.to_s.start_with?(HOMEBREW_CELLAR.to_s)
runtime_identity = Digest::SHA256.file(runtime_path).hexdigest
pid = Process.pid

execution = BrewCooldown::Prototype::Execution.new(map, state_directory: ENV.fetch("HOMEBREW_COOLDOWN_TEST_STATE"))
result = execution.apply(expected_inventory: inventory)
puts JSON.pretty_generate(result)
raise "Interpreter operation failed" unless result.fetch("status") == "completed"
raise "Tool runtime changed during upgrade" unless Process.pid == pid &&
  Pathname(RbConfig.ruby).realpath == runtime_path && Digest::SHA256.file(runtime_path).hexdigest == runtime_identity
output, status = Open3.capture2((candidate.formula.opt_prefix/"bin/ruby").to_s,
                              "-ropenssl", "-rpsych", "-e", "puts RUBY_VERSION; puts Psych.dump(OpenSSL::OPENSSL_VERSION)")
raise "Installed interpreter or native dependencies failed" unless status.success? && output.lines.first.chomp == record.fetch("version")
puts "PASS #{phase}: formula-managed Ruby works and Homebrew's running interpreter remains intact"
