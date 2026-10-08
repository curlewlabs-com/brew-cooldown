# frozen_string_literal: true

require_relative "../../lib/brew_cooldown/executor/cask_candidate"

Contract = BrewCooldown::Executor::NativeCaskContract

def recipe(name, mode = "upgrade")
  path = Pathname(File.join(__dir__, "../fixtures/native_casks/#{name}-#{mode}.rb")).expand_path
  BrewCooldown::Executor::CaskCandidate::SourceLoader.new(path, name:, commit: "a" * 40).load(config: nil)
end

def refused(message)
  yield
rescue BrewCooldown::Executor::Refused => error
  raise unless error.message.include?(message)
else
  raise "Unqualified native behavior was accepted: #{message}"
end

# These are unmodified upstream recipes, not a model of Homebrew's DSL. A
# historical version can qualify without blessing changed native side effects.
%w[gcloud-cli tailscale-app].each do |name|
  %w[baseline upgrade].each { |mode| Contract.validate!(recipe(name, mode)) }
  # Actual API-installed metadata omits installer/PKG artifacts and dependencies.
  # Requiring a candidate's full signature would strand these installations.
  path = Pathname(File.join(__dir__, "../fixtures/native_casks/#{name}-installed.json")).expand_path
  tab = Cask::Tab.from_file_content(path.read, path)
  installed = Cask::CaskLoader::FromAPILoader.new(name,
    from_json: { "version" => tab.version, "artifacts" => tab.uninstall_artifacts },
    path:, from_installed_caskfile: true, api_fallback: false).load(config: nil)
  installed.define_singleton_method(:tab) { tab }
  Contract.validate!(installed, predecessor: true)
  uninstall = installed.artifacts.find { |artifact| artifact.is_a?(Cask::Artifact::Uninstall) }
  uninstall.directives[:delete] = ["/Applications/Other.app"]
  refused("not qualified") { Contract.validate!(installed, predecessor: true) }
end

# A token or auto_updates flag alone must not license a script, privileged
# package option, new hook, or broader uninstall deletion.
cask = recipe("gcloud-cli")
installer = cask.artifacts.find { |artifact| artifact.is_a?(Cask::Artifact::Installer) }
installer.args[:args] << "--override-components"
refused("not qualified") { Contract.validate!(cask) }

cask = recipe("gcloud-cli")
steps = cask.artifacts.find { |artifact| artifact.is_a?(Cask::Artifact::PostflightSteps) }.steps
steps.find { |step| step["type"] == "run" }.fetch("args") << "unexpected"
refused("not qualified") { Contract.validate!(cask) }

cask = recipe("tailscale-app")
cask.artifacts.find { |artifact| artifact.is_a?(Cask::Artifact::Pkg) }.stanza_options[:allow_untrusted] = true
refused("not qualified") { Contract.validate!(cask) }

cask = recipe("tailscale-app")
cask.artifacts.find { |artifact| artifact.is_a?(Cask::Artifact::Uninstall) }.directives[:delete] << "/Applications/Other.app"
refused("not qualified") { Contract.validate!(cask) }

cask = Cask::Cask.new("another-app") { version "1.0.0"; auto_updates true }
refused("separate execution contract") { Contract.validate!(cask) }

# SDK restoration uses the old recipe's version, not the failed successor's
# fixed-version setting, and leaves the caller's environment intact afterward.
old, selected = recipe("gcloud-cli", "baseline"), recipe("gcloud-cli")
with_env(CLOUDSDK_COMPONENT_MANAGER_FIXED_SDK_VERSION: "caller-value") do
  Contract.with_installer_environment(selected) do
    raise "Selected SDK was not fixed" unless ENV.fetch("CLOUDSDK_COMPONENT_MANAGER_FIXED_SDK_VERSION") == selected.version.to_s
    Contract.with_installer_environment(old) do
      raise "Restoration inherited the successor version" unless ENV.fetch("CLOUDSDK_COMPONENT_MANAGER_FIXED_SDK_VERSION") == old.version.to_s
    end
    raise "Restoration leaked its version" unless ENV.fetch("CLOUDSDK_COMPONENT_MANAGER_FIXED_SDK_VERSION") == selected.version.to_s
  end
  raise "Installer changed caller environment" unless ENV.fetch("CLOUDSDK_COMPONENT_MANAGER_FIXED_SDK_VERSION") == "caller-value"
end

# Component snapshots removed during an operation still belong to that SDK;
# sibling payloads and paths outside its metadata directory never do.
raise "Deleted SDK snapshot lost ownership" unless Contract.owns_path?(selected, "#{HOMEBREW_PREFIX}/share/google-cloud-sdk/.install/removed.snapshot.json")
raise "SDK operation owns another package" if Contract.owns_path?(selected, "#{HOMEBREW_PREFIX}/share/other/VERSION")
raise "SDK operation owns arbitrary payload paths" if Contract.owns_path?(selected, "#{HOMEBREW_PREFIX}/share/google-cloud-sdk/other.snapshot.json")
puts "PASS: recorded native cask contracts, changed hook/installer/uninstall refusal and version-bound restoration"
