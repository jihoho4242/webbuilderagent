# frozen_string_literal: true

module Aiweb
  module Runtime
    class CommandSpec
      SHELL_META_PATTERN = /[|;&<>`]/

      attr_reader :argv, :cwd, :env, :timeout, :max_output_bytes, :risk_class, :description

      def initialize(argv:, cwd:, env: {}, timeout: 120, max_output_bytes: 200_000, risk_class: "local_process", description: nil)
        @argv = Array(argv).map(&:to_s)
        @cwd = cwd.to_s
        @env = env.transform_keys(&:to_s)
        @timeout = timeout
        @max_output_bytes = max_output_bytes
        @risk_class = risk_class
        @description = description || @argv.join(" ")
        validate!
      end

      def command
        argv.join(" ")
      end

      def validate!
        raise ArgumentError, "command argv must not be empty" if argv.empty? || argv.first.to_s.empty?
        raise ArgumentError, "command cwd must not be empty" if cwd.empty?
        argv.each do |part|
          raise ArgumentError, "unsafe shell metacharacter in argv element #{part.inspect}" if part.match?(SHELL_META_PATTERN)
        end
        true
      end
    end
  end
end
