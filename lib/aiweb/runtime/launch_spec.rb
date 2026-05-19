# frozen_string_literal: true

module Aiweb
  module Runtime
    class LaunchSpec
      SHELL_META_PATTERN = /[|;&<>`]/

      attr_reader :argv, :cwd, :env, :stdin, :stdout, :stderr, :unsetenv_others, :risk_class, :description

      def initialize(argv:, cwd:, env: {}, stdin: File::NULL, stdout: File::NULL, stderr: File::NULL, unsetenv_others: true, risk_class: "long_running_local_process", description: nil, allow_shell_meta: false)
        @argv = Array(argv).map(&:to_s)
        @cwd = cwd.to_s
        @env = env.transform_keys(&:to_s)
        @stdin = stdin
        @stdout = stdout
        @stderr = stderr
        @unsetenv_others = unsetenv_others
        @risk_class = risk_class
        @description = description || @argv.join(" ")
        @allow_shell_meta = allow_shell_meta
        validate!
      end

      def command
        argv.join(" ")
      end

      private

      def validate!
        raise ArgumentError, "launch argv must not be empty" if argv.empty? || argv.first.to_s.empty?
        raise ArgumentError, "launch cwd must not be empty" if cwd.empty?
        argv.each do |part|
          next if @allow_shell_meta

          raise ArgumentError, "unsafe shell metacharacter in launch argv element #{part.inspect}" if part.match?(SHELL_META_PATTERN)
        end
        true
      end
    end
  end
end
