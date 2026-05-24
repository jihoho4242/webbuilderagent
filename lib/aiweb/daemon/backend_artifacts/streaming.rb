# frozen_string_literal: true

module Aiweb
  module BackendArtifacts
    def run_stream_payload(path, run_id, cursor, limit, wait_ms = nil)
      root = safe_project_path(path)
      safe_id = safe_run_id!(run_id)
      relative, lines = run_event_lines(root, safe_id)
      offset = parse_nonnegative_integer(cursor, default: 0, label: "cursor")
      size = parse_nonnegative_integer(limit, default: 200, label: "limit")
      wait = [parse_nonnegative_integer(wait_ms, default: 0, label: "wait_ms"), 5000].min
      size = [[size, 1].max, 500].min

      if wait.positive? && lines.length <= offset
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + (wait / 1000.0)
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          sleep 0.05
          _relative, lines = run_event_lines(root, safe_id)
          break if lines.length > offset
        end
      end

      events = safe_jsonl_events(lines.drop(offset).first(size))
      next_cursor = offset + events.length
      {
        "schema_version" => 1,
        "status" => "ready",
        "project_path" => root,
        "run_id" => safe_id,
        "events_path" => relative,
        "stream_mode" => "long_poll",
        "wait_ms" => wait,
        "cursor" => offset,
        "next_cursor" => next_cursor,
        "has_more" => lines.length > next_cursor,
        "total_count" => lines.length,
        "events" => events
      }
    end

    def run_events_sse_body(path, run_id, cursor, limit, wait_ms = nil)
      stream = run_stream_payload(path, run_id, cursor, limit, wait_ms)
      chunks = []
      chunks << sse_comment("aiweb engine-run events")
      chunks << sse_event(
        event: "aiweb.run.meta",
        id: stream.fetch("cursor"),
        data: stream.slice("schema_version", "status", "project_path", "run_id", "events_path", "stream_mode", "wait_ms", "cursor", "next_cursor", "has_more", "total_count").merge("stream_mode" => "sse")
      )
      stream.fetch("events").each do |event|
        chunks << sse_event(
          event: event.fetch("type", "aiweb.event"),
          id: event.fetch("seq", stream.fetch("next_cursor")),
          data: event
        )
      end
      chunks << sse_event(
        event: "aiweb.run.cursor",
        id: stream.fetch("next_cursor"),
        data: {
          "schema_version" => 1,
          "run_id" => stream.fetch("run_id"),
          "cursor" => stream.fetch("cursor"),
          "next_cursor" => stream.fetch("next_cursor"),
          "has_more" => stream.fetch("has_more"),
          "total_count" => stream.fetch("total_count")
        }
      )
      chunks.join
    end

    def sse_comment(text)
      ": #{text.to_s.gsub(/[\r\n]+/, " ")}\n\n"
    end

    def sse_event(event:, id:, data:)
      body = +""
      body << "event: #{event.to_s.gsub(/[^A-Za-z0-9_.-]/, "-")}\n"
      body << "id: #{id}\n"
      JSON.generate(data).each_line do |line|
        body << "data: #{line.chomp}\n"
      end
      body << "\n"
      body
    end

    def run_events_payload(path, run_id)
      root = safe_project_path(path)
      safe_id = safe_run_id!(run_id)
      relative, lines = run_event_lines(root, safe_id)
      events = safe_jsonl_events(lines.last(200))
      {
        "schema_version" => 1,
        "status" => "ready",
        "project_path" => root,
        "run_id" => safe_id,
        "events_path" => relative,
        "events" => events,
        "count" => events.length
      }
    end

    def run_event_lines(root, run_id)
      relative = safe_artifact_path!(root, File.join(".ai-web", "runs", run_id, "events.jsonl"))
      full = File.join(root, relative)
      raise UserError.new("run events do not exist: #{relative}", 1) unless File.file?(full)
      safe_artifact_realpath!(root, full, relative)
      [relative, File.readlines(full, chomp: true)]
    end

    def safe_jsonl_events(lines)
      lines.map do |line|
        safe_metadata(JSON.parse(line))
      rescue JSON::ParserError
        { "status" => "unreadable", "raw" => redact_text(line.to_s)[0, 300] }
      end
    end
  end
end
