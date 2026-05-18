# frozen_string_literal: true

module Aiweb
  module Runtime
    module ProcessLauncher
      module_function

      def spawn(argv:, cwd:, env: {}, stdin: File::NULL, stdout: File::NULL, stderr: File::NULL, unsetenv_others: true)
        Process.spawn(
          EnvPolicy.clean_env(env),
          *argv,
          chdir: cwd,
          in: stdin,
          out: stdout,
          err: stderr,
          unsetenv_others: unsetenv_others
        )
      end
    end
  end
end
