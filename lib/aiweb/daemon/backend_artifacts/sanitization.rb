# frozen_string_literal: true

module Aiweb
  module BackendArtifacts
    def redact_text(text)
      text.to_s.gsub(self.class::SECRET_VALUE_PATTERN, "[redacted]").lines.map do |line|
        unsafe_env_path?(line) ? "[excluded unsafe .env reference]\n" : line
      end.join
    end

    def safe_json_summary(root, file)
      relative = file.sub(%r{\A#{Regexp.escape(root)}/?}, "")
      return nil if unsafe_env_path?(relative)

      data = JSON.parse(File.read(file))
      safe_metadata(data).merge("path" => relative, "size_bytes" => File.size(file))
    rescue JSON::ParserError, SystemCallError
      { "path" => relative, "status" => "unreadable" }
    end

    def safe_metadata(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), memo|
          key = key.to_s
          next if key.match?(self.class::SAFE_METADATA_DENY_KEY_PATTERN)
          next if key.match?(/secret|token|password|api[_-]?key|credential/i)
          next if unsafe_env_path?(item.to_s)

          memo[key] = safe_metadata(item)
        end
      when Array
        value.first(20).map { |item| safe_metadata(item) }
      when String
        return "[redacted]" if secret_value?(value)

        unsafe_env_path?(value) ? "[excluded]" : value[0, 300]
      else
        value
      end
    end

    def secret_value?(value)
      value.to_s.match?(self.class::SECRET_VALUE_PATTERN)
    end
  end
end
