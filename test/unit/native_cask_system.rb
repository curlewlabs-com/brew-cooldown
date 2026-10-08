# frozen_string_literal: true

require_relative "../../lib/brew_cooldown/executor/native_cask_system"
require_relative "../../lib/brew_cooldown/forked_component"

System = BrewCooldown::Executor::NativeCaskSystem

# An API name or malformed argument cannot become an arbitrary native call.
[[:other_api, "/tmp/path"], [:trash_paths, [nil]], [:trash_item, 42],
 [:bundle_identifier_for_pid, "1"], [:bundle_identifier_for_pid, 0]].each do |operation, argument|
  begin
    System.call(operation, argument)
  rescue BrewCooldown::Executor::Refused
    next
  end
  raise "Native API accepted unqualified input: #{operation}"
end

# A real AppKit call must work from the component's fork without inheriting
# lazy Objective-C initialization. This standalone Ruby PID is not an app.
System.activate
result = BrewCooldown::ForkedComponent.call(log: ->(**event) { warn JSON.generate(event) }) do
  identity = MacOS::FFI::AppKit.bundle_identifier_for_pid(Process.pid)
  raise "Standalone component acquired an app identity" unless identity.nil?

  { "status" => "completed" }
end
raise "Native app identity failed after fork: #{result}" unless result.fetch("status") == "completed"
puts "PASS: native AppKit after fork and closed native API inputs"
