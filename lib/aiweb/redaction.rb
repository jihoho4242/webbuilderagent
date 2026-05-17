# frozen_string_literal: true

module Aiweb
  module Redaction
    SECRET_VALUE_PATTERN = /
      (?:-----BEGIN\ [A-Z ]*PRIVATE\ KEY-----)|
      (?:\bAKIA[0-9A-Z]{16}\b)|
      (?:\b(?:ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]{10,}\b)|
      (?:\bxox[baprs]-[A-Za-z0-9-]{10,}\b)|
      (?:\b(?:sk|rk)_(?:live|test|proj)_[A-Za-z0-9_-]{10,}\b)|
      (?:\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b)
    /ix.freeze
    SECRET_KEY_PATTERN = /secret|token|password|api[_-]?key|credential/i.freeze
    SECRET_ENV_ASSIGNMENT_PATTERN = /\b[A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PRIVATE[_-]?KEY|API[_-]?KEY|CREDENTIAL)[A-Z0-9_]*=[^\s]+/i.freeze
    SECRET_QUERY_PATTERN = /([?&](?:access_token|api[_-]?key|key|password|secret|token)=)[^&\s]+/i.freeze
    ENV_FILE_REFERENCE_PATTERN = %r{(?<![\w.-])\.env(?:\.[A-Za-z0-9_-]+)?(?=$|[/:;,\s'"`)\]])}.freeze
    SECRET_ARG_FLAG_PATTERN = /\A--?[^=\s]*(?:token|secret|client[-_]?secret|password|passwd|api[-_]?key|auth|authorization|credential|private[-_]?key)[^=\s]*\z/i.freeze
    SECRET_ARG_ASSIGNMENT_PATTERN = /\A--?[^=\s]*(?:token|secret|client[-_]?secret|password|passwd|api[-_]?key|auth|authorization|credential|private[-_]?key)[^=\s]*=/i.freeze
    SECRET_LINE_PATTERN = /\b(?:KEY|[A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|PRIVATE[_-]?KEY|API[_-]?KEY|CREDENTIAL|AUTH)[A-Z0-9_]*|access[_-]?token|api[_-]?key|password|secret|token|credential|authorization)\s*[:=]/i.freeze

    module_function

    def secret_arg?(value, previous = nil)
      value.to_s.match?(SECRET_ARG_ASSIGNMENT_PATTERN) || previous.to_s.match?(SECRET_ARG_FLAG_PATTERN)
    end

    def redact_command(command, replacement: "[REDACTED]")
      previous = nil
      Array(command).map do |part|
        value = part.to_s
        redacted = secret_arg?(value, previous) ? replacement : value
        previous = value
        redacted
      end
    end

    def redact_event_value(value, depth: 0, replacement: "[redacted]")
      return "[redacted-depth-limit]" if depth > 8

      case value
      when Hash
        value.each_with_object({}) do |(key, item), memo|
          key = key.to_s
          memo[key] = key.match?(SECRET_KEY_PATTERN) ? replacement : redact_event_value(item, depth: depth + 1, replacement: replacement)
        end
      when Array
        value.map { |item| redact_event_value(item, depth: depth + 1, replacement: replacement) }
      when String
        redact_event_text(value, replacement: replacement)
      else
        value
      end
    end

    def redact_event_text(value, replacement: "[redacted]")
      value.to_s
        .gsub(SECRET_VALUE_PATTERN, replacement)
        .gsub(SECRET_ENV_ASSIGNMENT_PATTERN, replacement)
        .gsub(SECRET_QUERY_PATTERN, "\\1#{replacement}")
    end

    def redact_process_output(text, replacement: "[redacted]", base_redactor: nil)
      line_redacted = redact_secret_lines(text, replacement: replacement)
      redacted = base_redactor ? base_redactor.call(line_redacted) : line_redacted
      redacted = redact_event_text(redacted, replacement: replacement)
      redacted = redacted.gsub(/(Authorization:\s*Bearer\s+)[^\s]+/i, "\\1#{replacement}")
      redacted = redacted.gsub(/\b([A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|PRIVATE[_-]?KEY|API[_-]?KEY|CREDENTIAL|AUTH)[A-Z0-9_]*\s*:\s*)[^\s]+/i, "\\1#{replacement}")
      redacted = redacted.gsub(/\b((?:access[_-]?token|api[_-]?key|key|password|secret|token|credential|authorization)\s*:\s*)[^\s]+/i, "\\1#{replacement}")
      redacted.gsub(ENV_FILE_REFERENCE_PATTERN, "[excluded unsafe environment-file reference]")
    end

    def redact_secret_lines(text, replacement: "[redacted]")
      in_private_key_block = false
      text.to_s.lines.map do |line|
        if in_private_key_block
          in_private_key_block = false if private_key_end_line?(line)
          redacted_line(line, replacement)
        elsif secret_assignment_line?(line) || private_key_begin_line?(line)
          in_private_key_block = true if private_key_begin_line?(line) && !private_key_end_line?(line)
          redacted_line(line, replacement)
        else
          line
        end
      end.join
    end

    def secret_assignment_line?(line)
      line.to_s.match?(SECRET_LINE_PATTERN) || line.to_s.match?(/Authorization:\s*Bearer\s+/i)
    end

    def private_key_begin_line?(line)
      line.to_s.match?(/-----BEGIN [A-Z ]*PRIVATE KEY-----/i)
    end

    def private_key_end_line?(line)
      line.to_s.match?(/-----END [A-Z ]*PRIVATE KEY-----/i)
    end

    def redacted_line(line, replacement)
      line.to_s.end_with?("\n") ? "#{replacement}\n" : replacement
    end
  end
end
