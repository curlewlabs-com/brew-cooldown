# frozen_string_literal: true

require "cask/cask_loader"
require_relative "errors"

module BrewCooldown
  module Executor
    class CaskRetained
      attr_reader :cask

      def initialize(name)
        path = Cask::Cask.new(name).installed_caskfile
        raise Refused, "#{name}: installed cask metadata is missing" unless path

        @cask = Cask::CaskLoader.load_from_installed_caskfile(path, api_fallback: false)
        unless cask.token == name && cask.tab.version == cask.version.to_s
          raise Refused, "#{name}: installed cask identity differs from its receipt"
        end
      end

      def install? = false
    end
  end
end
