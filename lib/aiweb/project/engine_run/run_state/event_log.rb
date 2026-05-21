# frozen_string_literal: true

require "digest"

module Aiweb
  module ProjectEngineRun
    private

    def engine_run_event(path, events, type, message, data = {})
      seq = engine_run_next_event_seq(path, events)
      run_id = File.basename(File.dirname(path))
      event = {
        "schema_version" => 1,
        "seq" => seq,
        "run_id" => run_id,
        "actor" => "aiweb.engine_run",
        "phase" => type.to_s.split(".").first.to_s,
        "trace_span_id" => "span-#{seq.to_s.rjust(6, "0")}-#{type.to_s.gsub(/[^a-z0-9]+/i, "-")}",
        "type" => type,
        "message" => engine_run_redact_event_text(message.to_s),
        "at" => now,
        "data" => engine_run_redact_event_value(data),
        "redaction_status" => "redacted_at_source",
        "previous_event_hash" => engine_run_previous_event_hash(path, events)
      }
      event["event_hash"] = engine_run_event_hash(event)
      events << event
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "a") { |file| file.write(json_generate(event) + "\n") }
      event
    end

    def engine_run_redact_event_value(value, depth = 0)
      Aiweb::Redaction.redact_event_value(value, depth: depth)
    end

    def engine_run_redact_event_text(value)
      Aiweb::Redaction.redact_event_text(agent_run_redact_process_output(value.to_s))
    end

    def engine_run_previous_event_hash(path, events)
      last_event = events.reverse.find { |event| event["event_hash"].to_s.match?(/\Asha256:/) }
      return last_event["event_hash"] if last_event
      return nil unless File.file?(path)

      File.readlines(path).reverse_each do |line|
        parsed = JSON.parse(line)
        hash = parsed["event_hash"].to_s
        return hash if hash.match?(/\Asha256:/)
      rescue JSON::ParserError
        next
      end
      nil
    rescue SystemCallError
      nil
    end

    def engine_run_event_hash(event)
      payload = event.reject { |key, _value| key == "event_hash" }
      "sha256:#{Digest::SHA256.hexdigest(json_generate(payload))}"
    end

    def engine_run_next_event_seq(path, events)
      existing = File.file?(path) ? File.readlines(path).length : 0
      [existing, events.length].max + 1
    rescue SystemCallError
      events.length + 1
    end
  end
end
