# frozen_string_literal: true

module Aiweb
  module Runtime
    class ToolResult
      attr_reader :status, :stdout, :stderr, :exit_code, :command

      def initialize(status:, stdout:, stderr:, exit_code:, command:)
        @status = status
        @stdout = stdout
        @stderr = stderr
        @exit_code = exit_code
        @command = command
      end

      def success?
        status == "passed"
      end

      def to_h
        {
          "status" => status,
          "stdout" => stdout,
          "stderr" => stderr,
          "exit_code" => exit_code,
          "command" => command
        }
      end
    end
  end
end
