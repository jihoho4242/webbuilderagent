# frozen_string_literal: true

module Aiweb
  module Runtime
    module EnvPolicy
      SAFE_PASSTHROUGH_KEYS = %w[
        PATH Path SystemRoot WINDIR COMSPEC PATHEXT TMP TEMP HOME USERPROFILE
        LANG LC_ALL LC_CTYPE
      ].freeze
      SECRET_KEY_PATTERN = /(SECRET|TOKEN|KEY|PASSWORD|CREDENTIAL|PRIVATE|SUPABASE_SERVICE_ROLE)/i

      module_function

      def clean_env(extra = {})
        base = SAFE_PASSTHROUGH_KEYS.each_with_object({}) do |key, memo|
          memo[key] = ENV[key] if ENV.key?(key)
        end
        extra.each do |key, value|
          next if key.to_s.match?(SECRET_KEY_PATTERN)

          base[key.to_s] = value.to_s
        end
        base
      end

      def redact(text)
        text.to_s
          .gsub(/(SUPABASE_SERVICE_ROLE_KEY|SECRET|TOKEN|PASSWORD|PRIVATE_KEY|CREDENTIAL)(=|:)[^\s]+/i, "\\1\\2[REDACTED]")
          .gsub(/eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/, "[REDACTED_JWT]")
          .gsub(/sb_secret_[A-Za-z0-9_-]+/, "[REDACTED_SUPABASE_SECRET]")
      end
    end
  end
end
