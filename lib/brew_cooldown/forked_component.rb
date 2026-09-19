# frozen_string_literal: true

require "json"

module BrewCooldown
  module ForkedComponent
    def self.call(log:)
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        begin
          result = yield
        rescue StandardError => error
          log.call(operation: "execute_component", error: error.message, error_class: error.class.name, backtrace: error.backtrace)
          result = { "status" => "error", "error" => "#{error.class}: #{error.message}" }
        end
        writer.write(JSON.generate(result))
        writer.close
        exit! 0
      end
      writer.close
      contents = reader.read
      _child, status = Process.wait2(pid)
      unless status.success? && !contents.empty?
        return { "status" => "interrupted", "error" => "Component worker exited without a confirmed result: #{status}" }
      end
      JSON.parse(contents)
    ensure
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
    end
  end
end
