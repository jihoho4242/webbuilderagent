# frozen_string_literal: true

require "shellwords"

module Aiweb
  module Runtime
    class CommandSpec
      SHELL_META_PATTERN = /[|;&<>`]/

      attr_reader :argv, :cwd, :env, :stdin_data, :timeout, :max_output_bytes, :risk_class, :description

      def initialize(argv:, cwd:, env: {}, stdin_data: nil, timeout: 120, max_output_bytes: 200_000, risk_class: "local_process", description: nil, allow_shell_meta: false)
        @argv = Array(argv).map(&:to_s)
        @cwd = cwd.to_s
        @env = env.transform_keys(&:to_s)
        @stdin_data = stdin_data
        @timeout = timeout
        @max_output_bytes = max_output_bytes
        @risk_class = risk_class
        @description = description || @argv.join(" ")
        @allow_shell_meta = allow_shell_meta
        validate!
      end

      def command
        argv.join(" ")
      end

      def self.argv_from_command(command, default:)
        parts = Shellwords.split(command.to_s)
        parts.empty? ? Array(default).map(&:to_s) : parts
      rescue ArgumentError
        Array(default).map(&:to_s)
      end

      def validate!
        raise ArgumentError, "command argv must not be empty" if argv.empty? || argv.first.to_s.empty?
        raise ArgumentError, "command cwd must not be empty" if cwd.empty?
        argv.each do |part|
          next if @allow_shell_meta

          raise ArgumentError, "unsafe shell metacharacter in argv element #{part.inspect}" if part.match?(SHELL_META_PATTERN)
        end
        true
      end
    end
  end
end
