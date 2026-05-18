# frozen_string_literal: true

module Aiweb
  module ProjectPathSafety
    private

    def unsafe_env_path?(relative_path)
      Aiweb::Runtime::PathPolicy.unsafe_env_path?(relative_path)
    end

    def secret_looking_path?(relative_path)
      Aiweb::Runtime::PathPolicy.secret_looking_path?(relative_path)
    end

  end
end
