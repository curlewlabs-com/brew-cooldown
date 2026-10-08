# frozen_string_literal: true

require "json"
require "open3"
require_relative "errors"

module BrewCooldown
  module Executor
    # macOS refuses lazy Objective-C initialization in a forked component.
    # Native APIs run after exec; their arguments never become program source.
    module NativeCaskSystem
      def self.call(operation, value)
        expression, argument = case operation
        when :trash_paths
          unless value.is_a?(Array) && value.all? { |path| path.is_a?(String) }
            raise Refused, "native Trash requires path strings"
          end
          ["MacOS::FFI::Foundation.trash_paths(JSON.parse(ARGV.fetch(0)))", JSON.generate(value)]
        when :trash_item
          raise Refused, "native Trash requires a path string" unless value.is_a?(String)

          ["MacOS::FFI::Foundation.trash_item(ARGV.fetch(0))", value]
        when :bundle_identifier_for_pid
          raise Refused, "native app identity requires a process ID" unless value.is_a?(Integer) && value.positive?

          ["MacOS::FFI::AppKit.bundle_identifier_for_pid(Integer(ARGV.fetch(0)))", value.to_s]
        else
          raise Refused, "unqualified native system API: #{operation}"
        end
        output, diagnostics, status = Open3.capture3(*HOMEBREW_RUBY_EXEC_ARGS,
          "-I", $LOAD_PATH.join(File::PATH_SEPARATOR), "-rglobal", "-rjson", "-ros/mac/ffi",
          "-e", "puts JSON.generate(#{expression})", "--", argument)
        warn diagnostics unless diagnostics.empty?
        raise Refused, "native system API #{operation} failed: #{status}" unless status.success?

        result = JSON.parse(output)
        valid = if operation == :trash_paths
          result.is_a?(Array) && result.length == 2 && result.all? do |paths|
            paths.is_a?(Array) && paths.all? { |path| path.is_a?(String) }
          end
        else
          result.nil? || result.is_a?(String)
        end
        raise Refused, "native system API #{operation} returned invalid evidence" unless valid

        result
      end

      def self.activate
        require "os/mac/ffi"
        MacOS::FFI::Foundation.singleton_class.prepend(Foundation)
        MacOS::FFI::AppKit.singleton_class.prepend(AppKit)
      end

      module Foundation
        def trash_paths(paths)
          NativeCaskSystem.call(:trash_paths, paths)
        end

        def trash_item(path)
          NativeCaskSystem.call(:trash_item, path)
        end
      end

      module AppKit
        def bundle_identifier_for_pid(pid)
          NativeCaskSystem.call(:bundle_identifier_for_pid, pid)
        end
      end
    end
  end
end
