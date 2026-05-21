# frozen_string_literal: true

require "json"

module Aiweb
  module JsonSafety
    module_function

    def generate(value)
      JSON.generate(safe_value(value))
    end

    def pretty_generate(value)
      JSON.pretty_generate(safe_value(value))
    end

    def safe_value(value)
      case value
      when String
        safe_string(value)
      when Array
        value.map { |entry| safe_value(entry) }
      when Hash
        value.each_with_object({}) do |(key, entry), memo|
          memo[safe_value(key)] = safe_value(entry)
        end
      else
        value
      end
    end

    def safe_string(value)
      string = value.dup
      string = string.force_encoding(Encoding::UTF_8) if string.encoding == Encoding::BINARY || string.encoding == Encoding::ASCII_8BIT
      return string if string.encoding == Encoding::UTF_8 && string.valid_encoding?

      string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�")
    rescue EncodingError
      value.to_s.bytes.map { |byte| byte < 128 ? byte.chr : "�" }.join
    end
  end
end
