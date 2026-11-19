# frozen_string_literal: true

require "open3"
require "yaml"

# The Homebrew release workflow merges a qualified proposal that main has moved
# past only when this script lists none of main's changes. A path it wrongly
# leaves out would merge a Homebrew commit with an adapter no track ran against.
project = File.expand_path("../..", __dir__)
script = File.join(project, "script/qualification-reads")

def reads(script, *paths)
  output, status = Open3.capture2(script, stdin_data: paths.map { |path| "#{path}\n" }.join)
  raise "script/qualification-reads failed with #{status}" unless status.success?

  output.split("\n")
end

# The case that left a qualified proposal waiting for a person: main took CI pin
# bumps while the proposal's run was going.
unread = reads(script, ".github/workflows/ci.yml", ".github/workflows/dependabot-automerge.yml",
               ".github/ISSUE_TEMPLATE/bug_report.yml", ".github/pull_request_template.md")
raise "CI-only changes were counted as qualification inputs: #{unread}" unless unread.empty?

# The Qualify workflow itself, and everything a track reaches from the checkout.
read = [".github/workflows/qualify.yml", "lib/brew_cooldown/validated_homebrew.rb", "bin/brew-cooldown",
        "script/qualify", "test/integration/registry.rb", "examples/conservative.json", "README.md",
        ".github/actions/setup/action.yml", "a new top-level file"]
listed = reads(script, *read)
raise "Qualification inputs went unlisted: #{read - listed}" unless listed == read

# The unread .github/ paths stay unread only while the Qualify workflow pulls
# nothing in from them.
workflow = YAML.safe_load_file(File.join(project, ".github/workflows/qualify.yml"))
uses = workflow.fetch("jobs").values.flat_map do |job|
  [job["uses"], *job.fetch("steps", []).map { |step| step["uses"] }].compact
end
raise "Found no action in qualify.yml; the check below would pass on nothing" if uses.empty?

local = uses.select { |reference| reference.start_with?("./") }
raise "qualify.yml uses #{local}; script/qualification-reads must list them" unless local.empty?

puts "PASS: only files outside every Qualify run let an older qualification stand"
