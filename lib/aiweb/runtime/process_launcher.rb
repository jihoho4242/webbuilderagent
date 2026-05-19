# frozen_string_literal: true

module Aiweb
  module Runtime
    module ProcessLauncher
      module_function

      def spawn(spec:)
        Process.spawn(
          EnvPolicy.clean_env(spec.env),
          *spec.argv,
          chdir: spec.cwd,
          in: spec.stdin,
          out: spec.stdout,
          err: spec.stderr,
          unsetenv_others: spec.unsetenv_others
        )
      end
    end
  end
end
