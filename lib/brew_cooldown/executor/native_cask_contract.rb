# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require_relative "errors"

module BrewCooldown
  module Executor
    # Native SDK and PKG payloads can advance without updating a Homebrew Tab.
    # The receipt remains authoritative only while these payloads agree with it.
    module NativeCaskContract
      # These bind executable artifact behavior, not release identity. Changing
      # a hook, installer argument or uninstall action requires VM qualification.
      # The recorded recipes and evidence are described in docs/cask-execution.md.
      SIGNATURES = {
        "gcloud-cli" => "048309f737ba458adac6438e2eff51035cb538e6a886161d85cd7ccd777e92cc",
        "tailscale-app" => "ae3a2178cef658cce3994e5c7ee8822be1b3b0b36363e51897c308cd2b58212e"
      }.freeze
      UNINSTALL_SIGNATURES = {
        "gcloud-cli" => "d31497a4732e376e5693623508a7773f2e2a8381c42d40961cffae921a4459a2",
        "tailscale-app" => "1003116b5f39cfb6c025a29af9dc1cc45f5e83b18799c44f9cee76b51a97e34e"
      }.freeze

      def self.supported?(cask)
        SIGNATURES.key?(cask.token) && (cask.tap&.name || cask.tab.source["tap"]) == "homebrew/cask"
      end

      def self.validate!(cask, predecessor: false)
        raise Refused, "self-updating cask needs a separate execution contract" unless supported?(cask)
        if cask.token == "tailscale-app" && cask.config.appdir.to_s != "/Applications"
          raise Refused, "tailscale-app: native PKG contract requires /Applications"
        end
        signatures = predecessor ? UNINSTALL_SIGNATURES : SIGNATURES
        unless (predecessor || cask.auto_updates) && signature(cask, uninstall_only: predecessor) == signatures.fetch(cask.token)
          raise Refused, "#{cask.token}: native installer or hook behavior is not qualified"
        end
      end

      def self.signature(cask, uninstall_only: false)
        # Native ordering among artifacts of the same class is not stable.
        # Preserve order inside each structured hook and its argument lists.
        artifacts = cask.artifacts.filter_map do |artifact|
          next if uninstall_only && !artifact.respond_to?(:uninstall_phase) && !artifact.respond_to?(:post_uninstall_phase) &&
                  !artifact.is_a?(Cask::Artifact::Zap)
          raise Refused, "#{cask.token}: opaque Ruby cask hooks are not qualified" if artifact.is_a?(Cask::Artifact::AbstractFlightBlock)

          args = artifact.to_args
          if artifact.instance_of?(Cask::Artifact::Pkg)
            unless args == ["Tailscale-#{cask.version}-macos.pkg"]
              raise Refused, "#{cask.token}: unqualified PKG path or installation options"
            end
            args = ["Tailscale-{{version}}-macos.pkg"]
          end
          entry = { "class" => artifact.class.name, "args" => args }
          if artifact.instance_of?(Cask::Artifact::Installer)
            entry["installer"] = { "path" => artifact.path.to_s, "args" => artifact.args, "manual" => artifact.manual_install }
          end
          entry["options"] = artifact.stanza_options if artifact.instance_of?(Cask::Artifact::Pkg)
          entry["directives"] = artifact.directives if artifact.is_a?(Cask::Artifact::AbstractUninstall)
          entry["target"] = artifact.target.to_s if artifact.is_a?(Cask::Artifact::Relocated)
          canonical(entry)
        end.sort_by { |entry| JSON.generate(entry) }
        contract = { artifacts: }
        contract.merge!(formula: cask.depends_on.formula, cask: cask.depends_on.cask) unless uninstall_only
        Digest::SHA256.hexdigest(JSON.generate(contract))
      end

      def self.canonical(value)
        case value
        when Hash then value.keys.sort_by(&:to_s).to_h { |key| [key.to_s, canonical(value.fetch(key))] }
        when Array then value.map { |entry| canonical(entry) }
        when Pathname then value.to_s
        else value
        end
      end

      def self.files(name)
        case name
        when "gcloud-cli"
          root = HOMEBREW_PREFIX/"share/google-cloud-sdk"
          [root/"VERSION", *root.glob(".install/*.snapshot.json")]
        when "tailscale-app"
          [Pathname("/Applications/Tailscale.app/Contents/Info.plist"),
           Pathname("/var/db/receipts/com.tailscale.ipn.macsys.plist"),
           Pathname("/var/db/receipts/com.tailscale.ipn.macsys.bom")]
        else []
        end
      end

      def self.owns_path?(cask, path)
        return false unless supported?(cask)
        if cask.token == "gcloud-cli"
          root = HOMEBREW_PREFIX/"share/google-cloud-sdk"
          entry = Pathname(path)
          return entry == root/"VERSION" || (entry.dirname == root/".install" && entry.basename.to_s.end_with?(".snapshot.json"))
        end

        files(cask.token).any? { |file| file.to_s == path }
      end

      def self.verify_installed!(cask)
        return unless supported?(cask)

        versions = case cask.token
        when "gcloud-cli"
          paths = files(cask.token)
          core = HOMEBREW_PREFIX/"share/google-cloud-sdk/.install/core.snapshot.json"
          raise Refused, "gcloud-cli: native component snapshot is missing" unless paths.include?(core)

          [paths.first.read.strip, *paths.drop(1).map { |path| JSON.parse(path.read).fetch("version") }]
        when "tailscale-app"
          executable = Pathname("/Applications/Tailscale.app/Contents/MacOS/Tailscale")
          raise Refused, "tailscale-app: native package evidence is missing" unless files(cask.token).all?(&:file?)
          raise Refused, "tailscale-app: installed executable is missing" unless executable.file? && executable.executable?
          unless plist_value(files(cask.token).fetch(0), "CFBundleIdentifier") == "io.tailscale.ipn.macsys"
            raise Refused, "tailscale-app: installed bundle identity differs"
          end
          [plist_value(files(cask.token).fetch(0), "CFBundleShortVersionString"),
           plist_value(files(cask.token).fetch(1), "PackageVersion")]
        end
        unless versions.all? { |version| version == cask.version.to_s }
          raise Refused, "#{cask.token}: live payload #{versions.inspect} differs from Homebrew receipt #{cask.version}; " \
                         "inspect external updates before selecting an upgrade"
        end
      end

      def self.plist_value(path, key)
        output, status = Open3.capture2e("/usr/bin/plutil", "-extract", key, "raw", "-o", "-", path.to_s)
        raise Refused, "read native cask payload #{path}: #{output.strip}" unless status.success?

        output.strip
      end

      def self.with_installer_environment(cask)
        return yield unless supported?(cask) && cask.token == "gcloud-cli"

        # The vendor installer can restore optional components over the network.
        # Its own fixed-version property keeps that work on the selected SDK.
        with_env(CLOUDSDK_COMPONENT_MANAGER_FIXED_SDK_VERSION: cask.version.to_s,
                 CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK: "true") { yield }
      end
    end
  end
end
