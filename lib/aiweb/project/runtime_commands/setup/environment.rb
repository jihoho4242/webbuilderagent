# frozen_string_literal: true

require "json"

module Aiweb
  module ProjectRuntimeSetupEnvironment
    private

    def setup_supply_chain_registry_url
      "https://registry.npmjs.org/"
    end

    def setup_supply_chain_registry_host
      "registry.npmjs.org"
    end

    def read_package_json_object
      path = File.join(root, "package.json")
      return {} unless File.file?(path)

      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : {}
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def setup_child_env
      %w[
        PATH
        PATHEXT
        SYSTEMROOT
        SystemRoot
        WINDIR
        COMSPEC
        HOME
        USERPROFILE
        TMP
        TEMP
      ].each_with_object({}) do |key, env|
        env[key] = ENV[key] if ENV[key]
      end.merge("AIWEB_SETUP_APPROVED" => "1")
    end

    def setup_child_env_policy
      child_env = setup_child_env
      secret_keys = %w[
        SECRET
        NPM_TOKEN
        NODE_AUTH_TOKEN
        YARN_NPM_AUTH_TOKEN
        PNPM_HOME_TOKEN
        OPENAI_API_KEY
        ANTHROPIC_API_KEY
        AWS_SECRET_ACCESS_KEY
        GOOGLE_APPLICATION_CREDENTIALS
      ]
      {
        "unsetenv_others" => true,
        "allowed_env_keys" => child_env.keys.sort,
        "secret_parent_env_keys_stripped" => secret_keys.select { |key| ENV.key?(key) },
        "secret_values_recorded" => false,
        "aiweb_setup_approved" => child_env["AIWEB_SETUP_APPROVED"] == "1"
      }
    end

    def redact_setup_output(output)
      output.to_s
        .gsub(/(SECRET|TOKEN|PASSWORD|PASSWD|PRIVATE|CREDENTIAL|API[_-]?KEY)([A-Z0-9_ -]*)(=|:)[^\s]+/i, '\1\2\3[REDACTED]')
        .gsub(/(sk|pk|sb_secret)_[A-Za-z0-9_-]{12,}/, '[REDACTED]')
        .gsub(/eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/, '[REDACTED]')
    end
  end
end
