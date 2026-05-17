# frozen_string_literal: true

require_relative "../authz_contract"

module Aiweb
  module BackendArtifacts
    def console_payload(path)
      root = safe_project_path(path)
      runs = runs_payload(root).fetch("runs")
      approvals = approvals_payload(root).fetch("approvals")
      {
        "schema_version" => 1,
        "status" => "ready",
        "project_path" => root,
        "console" => {
          "backend_ready" => true,
          "frontend_attached" => false,
          "latest_run" => runs.last,
          "recent_run_count" => runs.length,
          "approval_count" => approvals.length,
          "approvals" => approvals.last(20),
          "routes" => self.class.routes,
          "capabilities" => {
            "engine_run" => true,
            "engine_run_async_jobs" => true,
            "approval_resume" => true,
            "approval_resume_jobs" => true,
            "openmanus_readiness" => true,
            "run_detail" => true,
            "event_polling" => true,
            "event_sse" => true,
            "diff_artifacts" => true,
            "sse" => true,
            "websocket" => false
          }
        }
      }
    end

    def runs_payload(path)
      root = safe_project_path(path)
      pattern = File.join(root, ".ai-web", "runs", "*", "*.json")
      runs = Dir.glob(pattern).sort.last(30).map do |file|
        safe_json_summary(root, file)
      end.compact
      {
        "schema_version" => 1,
        "status" => "ready",
        "project_path" => root,
        "runs" => runs
      }
    end

    def run_detail_payload(path, run_id)
      root = safe_project_path(path)
      safe_id = safe_run_id!(run_id)
      run_dir = File.join(root, ".ai-web", "runs", safe_id)
      raise UserError.new("run does not exist: #{safe_id}", 1) unless Dir.exist?(run_dir)

      metadata = run_metadata_summary(root, safe_id)
      events_payload = run_stream_payload(root, safe_id, 0, 200)
      approvals = run_approvals(root, safe_id)
      artifact_refs = run_artifact_refs(root, safe_id, metadata)
      panels = run_typed_panels(root, safe_id, metadata, artifact_refs, events_payload, approvals)
      run_status = metadata["status"].to_s
      {
        "schema_version" => 1,
        "status" => "ready",
        "project_path" => root,
        "run" => {
          "run_id" => safe_id,
          "metadata" => metadata,
          "events" => events_payload.fetch("events"),
          "event_count" => events_payload.fetch("total_count"),
          "approvals" => approvals,
          "artifact_refs" => artifact_refs,
          "panels" => panels,
          "console" => {
            "needs_approval" => run_status == "waiting_approval" || approvals.any? { |entry| entry["status"].to_s == "planned" },
            "can_resume" => %w[waiting_approval cancelled failed blocked].include?(run_status),
            "latest_event_type" => events_payload.fetch("events").last&.fetch("type", nil)
          }
        }
      }
    end

    def run_typed_panels(root, _run_id, metadata, artifact_refs, events_payload, approvals)
      {
        "eval_benchmark" => run_json_panel(root, metadata["eval_benchmark_path"], metadata["eval_benchmark"]),
        "supply_chain_gate" => run_json_panel(root, metadata["supply_chain_gate_path"], metadata["supply_chain_gate"]),
        "run_memory" => run_json_panel(root, metadata["run_memory_path"], metadata["run_memory"]),
        "authz_enforcement" => run_json_panel(root, metadata["authz_enforcement_path"], metadata["authz_enforcement"]),
        "worker_adapter_registry" => run_json_panel(root, metadata["worker_adapter_registry_path"], metadata["worker_adapter_registry"]),
        "design_verdict" => run_json_panel(root, metadata["design_verdict_path"], metadata["design_verdict"]),
        "screenshots" => run_screenshots_panel(root, metadata["screenshot_evidence_path"], metadata["screenshot_evidence"]),
        "preview" => run_json_panel(root, metadata["preview_path"], metadata["preview"]),
        "diff" => {
          "status" => artifact_refs.any? { |ref| ref["role"] == "diff" } ? "ready" : "empty",
          "artifact" => artifact_refs.find { |ref| ref["role"] == "diff" }
        },
        "opendesign_contract" => run_json_panel(root, metadata["opendesign_contract_path"], metadata["opendesign_contract"]),
        "repair_history" => {
          "status" => "ready",
          "events" => events_payload.fetch("events").select { |event| event["type"].to_s.start_with?("design.repair.") || event["type"].to_s == "repair.planned" }
        },
        "approvals" => {
          "status" => approvals.empty? ? "empty" : "ready",
          "items" => approvals
        }
      }
    end

    def run_json_panel(root, path, inline)
      relative = path.to_s
      data = inline
      if data.nil? && !relative.empty? && safe_artifact_reference?(root, relative)
        full = File.join(root, relative)
        data = safe_json_summary(root, full) if File.file?(full)
      end
      {
        "status" => data.nil? ? "empty" : "ready",
        "path" => relative.empty? ? nil : relative,
        "data" => data
      }.compact
    rescue UserError
      { "status" => "blocked", "path" => relative }
    end

    def run_screenshots_panel(root, path, inline)
      panel = run_json_panel(root, path, inline)
      screenshots = Array(panel.dig("data", "screenshots")).map do |shot|
        shot.slice("viewport", "width", "height", "url", "path", "sha256", "capture_mode")
      end
      panel.merge("screenshots" => screenshots)
    end

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

    def artifact_payload(path, artifact, headers: nil)
      root = safe_project_path(path)
      relative = safe_artifact_path!(root, artifact)
      artifact_acl = artifact_acl_classification(relative)
      validate_artifact_acl!(root, relative, headers, artifact_acl) if headers
      full = File.join(root, relative)
      raise UserError.new("artifact does not exist: #{relative}", 1) unless File.file?(full)
      safe_artifact_realpath!(root, full, relative)

      size = File.size(full)
      raise UserError.new("artifact is too large for safe read: #{relative}", 5) if size > self.class::SAFE_ARTIFACT_BYTES

      raw = File.read(full)
      redacted = redact_text(raw)
      parsed = safe_artifact_json(relative, raw)
      content = artifact_media_type(relative) == "application/json" && parsed ? JSON.pretty_generate(parsed) : redacted
      {
        "schema_version" => 1,
        "status" => "ready",
        "project_path" => root,
        "artifact" => {
          "path" => relative,
          "size_bytes" => size,
          "sha256" => Digest::SHA256.file(full).hexdigest,
          "media_type" => artifact_media_type(relative),
          "acl" => artifact_acl,
          "redacted" => redacted != raw || content != raw,
          "content" => content,
          "json" => parsed
        }.compact
      }
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

    def approvals_payload(path)
      root = safe_project_path(path)
      approvals = Dir.glob(File.join(root, ".ai-web", "runs", "*", "approvals.jsonl")).sort.last(50).flat_map do |file|
        relative = file.sub(%r{\A#{Regexp.escape(root)}/?}, "")
        next [] unless relative.match?(self.class::SAFE_ARTIFACT_PATTERN)
        safe_artifact_realpath!(root, file, relative)

        approval_records(File.basename(File.dirname(file)), relative, File.readlines(file, chomp: true))
      rescue SystemCallError, UserError
        []
      end
      {
        "schema_version" => 1,
        "status" => "ready",
        "project_path" => root,
        "approvals" => approvals.compact.last(100)
      }
    end

    def run_metadata_summary(root, run_id)
      run_dir = File.join(root, ".ai-web", "runs", run_id)
      preferred = %w[engine-run.json agent-run.json verify-loop.json setup.json build.json preview.json]
      file = preferred.map { |name| File.join(run_dir, name) }.find { |candidate| File.file?(candidate) }
      file ||= Dir.glob(File.join(run_dir, "*.json")).sort.first
      raise UserError.new("run metadata does not exist: #{run_id}", 1) unless file

      safe_json_summary(root, file).merge("run_id" => run_id)
    end

    def run_approvals(root, run_id)
      file = File.join(root, ".ai-web", "runs", run_id, "approvals.jsonl")
      return [] unless File.file?(file)

      relative = safe_artifact_path!(root, File.join(".ai-web", "runs", run_id, "approvals.jsonl"))
      safe_artifact_realpath!(root, file, relative)
      approval_records(run_id, relative, File.readlines(file, chomp: true))
    end

    def approval_records(run_id, relative, lines)
      lines.map do |line|
        safe_metadata(JSON.parse(line)).merge("run_id" => run_id, "path" => relative)
      rescue JSON::ParserError
        { "run_id" => run_id, "path" => relative, "status" => "unreadable" }
      end
    end

    def run_artifact_refs(root, run_id, metadata)
      refs = []
      metadata.to_h.each do |key, value|
        next unless key.end_with?("_path") || key == "diff_path"

        relative = value.to_s
        next if relative.empty?
        next unless safe_artifact_reference?(root, relative)

        refs << artifact_ref(root, relative, artifact_role(key, relative))
      end
      Dir.glob(File.join(root, ".ai-web", "runs", run_id, "{artifacts,logs,qa,screenshots}", "*")).sort.each do |file|
        next unless File.file?(file)

        relative = file.sub(%r{\A#{Regexp.escape(root)}/?}, "").tr("\\", "/")
        next unless safe_artifact_reference?(root, relative)

        refs << artifact_ref(root, relative, artifact_role(File.basename(file, ".*"), relative))
      end
      refs.uniq { |entry| entry["path"] }
    end

    def safe_artifact_reference?(root, relative)
      safe_artifact_path!(root, relative)
      true
    rescue UserError
      false
    end

    def artifact_ref(root, relative, role)
      full = File.join(root, relative)
      {
        "path" => relative,
        "role" => role,
        "media_type" => artifact_media_type(relative),
        "size_bytes" => File.file?(full) ? File.size(full) : nil
      }.compact
    end

    def artifact_role(key, relative)
      return "diff" if key == "diff_path" || relative.end_with?(".patch")

      key.sub(/_path\z/, "")
    end

    def artifact_acl_classification(relative)
      normalized = relative.to_s.tr("\\", "/")
      required_role = if normalized.match?(%r{\A\.ai-web/runs/[^/]+/approvals\.jsonl\z})
                        "admin"
                      elsif normalized.start_with?(".ai-web/diffs/") ||
                          normalized.match?(%r{\A\.ai-web/runs/[^/]+/logs/}) ||
                          normalized.match?(%r{\A\.ai-web/runs/[^/]+/artifacts/(?:agent-result|authz-enforcement|sandbox-preflight|supply-chain-gate|worker-adapter|mcp-broker|side-effect-broker)[A-Za-z0-9_.-]*\.(?:json|jsonl|log|txt|md)\z})
                        "operator"
                      else
                        "viewer"
                      end
      {
        "policy" => Aiweb::AuthzContract::ARTIFACT_ACL_POLICY.fetch("policy"),
        "required_role" => required_role,
        "category" => required_role == "viewer" ? "standard_safe_artifact" : "sensitive_run_artifact",
        "reason" => required_role == "viewer" ? "safe artifact allowlist and viewer role are sufficient" : "logs, diffs, approvals, and sensitive run artifacts require elevated project role"
      }
    end

    def safe_artifact_path!(root, artifact)
      text = artifact.to_s.strip
      raise UserError.new("artifact path is required", 1) if text.empty?
      raise UserError.new("artifact path must be relative", 5) if text.start_with?("/") || text.match?(/\A[a-z][a-z0-9+.-]*:\/\//i)
      raise UserError.new("unsafe artifact path blocked: null bytes are not allowed", 5) if text.include?("\x00")
      raise UserError.new("unsafe artifact path blocked: .env/.env.* paths are not allowed", 5) if unsafe_env_path?(text)

      normalized = text.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
      parts = normalized.split("/")
      if normalized.empty? || parts.any? { |part| part.empty? || part == ".." }
        raise UserError.new("unsafe artifact path blocked: path traversal is not allowed", 5)
      end
      unless normalized.match?(self.class::SAFE_ARTIFACT_PATTERN)
        raise UserError.new("artifact path is not on the safe read allowlist: #{normalized}", 5)
      end

      full = File.expand_path(normalized, root)
      aiweb_root = File.expand_path(File.join(root, ".ai-web"))
      unless full == aiweb_root || full.start_with?("#{aiweb_root}#{File::SEPARATOR}")
        raise UserError.new("unsafe artifact path blocked: artifact must stay under .ai-web", 5)
      end
      normalized
    end

    def safe_artifact_realpath!(root, full, relative)
      raise UserError.new("artifact symlinks are not readable: #{relative}", 5) if File.lstat(full).symlink?

      real = File.realpath(full)
      aiweb_root = File.realpath(File.join(root, ".ai-web"))
      unless real.start_with?("#{aiweb_root}#{File::SEPARATOR}")
        raise UserError.new("unsafe artifact path blocked: artifact must stay under .ai-web", 5)
      end
      true
    rescue Errno::ENOENT
      raise UserError.new("artifact does not exist: #{relative}", 1)
    end

    def artifact_media_type(path)
      case File.extname(path).downcase
      when ".json" then "application/json"
      when ".jsonl" then "application/x-jsonlines"
      when ".patch" then "text/x-diff"
      when ".html" then "text/html"
      when ".md" then "text/markdown"
      when ".log" then "text/plain"
      when ".png" then "image/png"
      when ".yml", ".yaml" then "application/yaml"
      else "text/plain"
      end
    end

    def safe_artifact_json(path, content)
      return nil unless File.extname(path).downcase == ".json"

      safe_metadata(JSON.parse(content))
    rescue JSON::ParserError
      nil
    end

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
