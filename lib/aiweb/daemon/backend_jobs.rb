# frozen_string_literal: true

require_relative "../redaction"

module Aiweb
  module BackendJobs
    def enqueue_engine_run_job(project_path:, run_id:, bridge_kwargs:, resume_from: nil)
      root = safe_project_path(project_path)
      run_dir = backend_run_dir(root, run_id)
      FileUtils.mkdir_p(run_dir)
      events_path = File.join(run_dir, "events.jsonl")
      job_path = File.join(run_dir, "job.json")
      queued_at = now_utc
      job = backend_job_record(
        run_id: run_id,
        status: "queued",
        project_path: root,
        started_at: nil,
        finished_at: nil,
        events_path: events_path,
        resume_from: resume_from,
        bridge_kwargs: bridge_kwargs,
        queued_at: queued_at
      )
      backend_write_json(job_path, job)
      backend_append_event(events_path, "backend.job.queued", "queued engine-run background job", run_id: run_id, resume_from: resume_from)
      start_engine_run_worker(root: root, run_id: run_id, job_path: job_path, events_path: events_path, bridge_kwargs: bridge_kwargs, queued_at: queued_at, resume_from: resume_from)
      engine_job_payload(root: root, run_id: run_id, job: job)
    end

    def start_engine_run_worker(root:, run_id:, job_path:, events_path:, bridge_kwargs:, queued_at:, resume_from:)
      thread = Thread.new do
        started_at = now_utc
        begin
          backend_write_json(job_path, backend_job_record(
            run_id: run_id,
            status: "running",
            project_path: root,
            started_at: started_at,
            finished_at: nil,
            events_path: events_path,
            resume_from: resume_from,
            bridge_kwargs: bridge_kwargs,
            queued_at: queued_at
          ))
          backend_append_event(events_path, "backend.job.started", "started engine-run background job", run_id: run_id, resume_from: resume_from)
          result = bridge_engine_run(**bridge_kwargs)
          final_status = backend_engine_job_status(result)
          backend_write_json(job_path, backend_job_record(
            run_id: run_id,
            status: final_status,
            project_path: root,
            started_at: started_at,
            finished_at: now_utc,
            events_path: events_path,
            resume_from: resume_from,
            bridge_kwargs: bridge_kwargs,
            queued_at: queued_at,
            bridge_status: result["status"],
            exit_code: result["exit_code"],
            engine_run_id: result.dig("stdout_json", "engine_run", "run_id") || run_id,
            engine_status: result.dig("stdout_json", "engine_run", "status"),
            blocking_issues: Array(result.dig("stdout_json", "blocking_issues")) + Array(result.dig("stdout_json", "engine_run", "blocking_issues"))
          ))
          backend_append_event(events_path, "backend.job.finished", "finished engine-run background job", run_id: run_id, status: final_status)
        rescue StandardError => e
          backend_write_json(job_path, backend_job_record(
            run_id: run_id,
            status: "failed",
            project_path: root,
            started_at: started_at,
            finished_at: now_utc,
            events_path: events_path,
            resume_from: resume_from,
            bridge_kwargs: bridge_kwargs,
            queued_at: queued_at,
            blocking_issues: ["#{e.class}: #{e.message}"]
          ))
          backend_append_event(events_path, "backend.job.failed", "engine-run background job failed", run_id: run_id, error: "#{e.class}: #{e.message}")
        ensure
          @job_mutex.synchronize { @background_jobs.delete(run_id) }
        end
      end
      thread.abort_on_exception = false
      @job_mutex.synchronize { @background_jobs[run_id] = thread }
      thread
    end

    def engine_job_payload(root:, run_id:, job:)
      {
        "schema_version" => 1,
        "status" => "queued",
        "project_path" => root,
        "engine_run" => {
          "schema_version" => 1,
          "run_id" => run_id,
          "status" => "queued",
          "job_path" => File.join(".ai-web", "runs", run_id, "job.json").tr("\\", "/"),
          "events_path" => job["events_path"],
          "async" => true,
          "stream" => {
            "route" => "GET /api/project/run-stream?path=PROJECT_PATH&run_id=#{run_id}&cursor=N&wait_ms=MS",
            "cursor" => 0
          },
          "approval_resume" => !job["resume_from"].to_s.empty?
        },
        "job" => job,
        "next_action" => "poll run-stream and job/status for #{run_id}"
      }
    end

    def backend_job_status_payload(root, run_id)
      path = File.join(backend_run_dir(root, run_id), "job.json")
      return nil unless File.file?(path)

      job = safe_json_summary(root, path)
      {
        "schema_version" => 1,
        "status" => "ready",
        "project_path" => root,
        "run_id" => run_id,
        "job" => job
      }
    end

    def backend_job_record(run_id:, status:, project_path:, started_at:, finished_at:, events_path:, resume_from:, bridge_kwargs:, queued_at:, bridge_status: nil, exit_code: nil, engine_run_id: nil, engine_status: nil, blocking_issues: [])
      relative_events = events_path.sub(%r{\A#{Regexp.escape(project_path)}[\\/]?}, "").tr("\\", "/")
      {
        "schema_version" => 1,
        "kind" => "engine-run",
        "run_id" => run_id,
        "status" => status,
        "queued_at" => queued_at,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "updated_at" => now_utc,
        "events_path" => relative_events,
        "resume_from" => resume_from,
        "bridge" => {
          "command" => "engine-run",
          "agent" => bridge_kwargs[:agent],
          "mode" => bridge_kwargs[:mode],
          "sandbox" => bridge_kwargs[:sandbox],
          "max_cycles" => bridge_kwargs[:max_cycles],
          "dry_run" => bridge_kwargs[:dry_run],
          "approved" => bridge_kwargs[:approved]
        },
        "bridge_status" => bridge_status,
        "exit_code" => exit_code,
        "engine_run_id" => engine_run_id,
        "engine_status" => engine_status,
        "blocking_issues" => Array(blocking_issues).compact.map(&:to_s).reject(&:empty?).uniq
      }.compact
    end

    def backend_engine_job_status(result)
      engine_status = result.dig("stdout_json", "engine_run", "status").to_s
      return engine_status unless engine_status.empty?

      result["status"].to_s == "passed" ? "passed" : "failed"
    end

    def backend_run_dir(root, run_id)
      File.join(root, ".ai-web", "runs", safe_run_id!(run_id))
    end

    def backend_write_json(path, payload)
      FileUtils.mkdir_p(File.dirname(path))
      temp = "#{path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
      File.write(temp, JSON.pretty_generate(payload) + "\n")
      File.rename(temp, path)
    ensure
      FileUtils.rm_f(temp) if temp && File.file?(temp)
    end

    def backend_append_event(path, type, message, data = {})
      FileUtils.mkdir_p(File.dirname(path))
      seq = backend_next_event_seq(path)
      run_id = data.fetch(:run_id, data.fetch("run_id", File.basename(File.dirname(path)))).to_s
      event = {
        "schema_version" => 1,
        "seq" => seq,
        "run_id" => run_id,
        "actor" => "aiweb.engine_run",
        "phase" => type.to_s.split(".").first.to_s,
        "trace_span_id" => "span-#{seq.to_s.rjust(6, "0")}-#{type.to_s.gsub(/[^a-z0-9]+/i, "-")}",
        "type" => type,
        "message" => backend_redact_event_text(message.to_s),
        "at" => now_utc,
        "data" => backend_redact_event_value(data),
        "redaction_status" => "redacted_at_source",
        "previous_event_hash" => backend_previous_event_hash(path)
      }
      event["event_hash"] = backend_event_hash(event)
      File.open(path, "a") { |file| file.write(JSON.generate(event) + "\n") }
      event
    end

    def backend_previous_event_hash(path)
      return nil unless File.file?(path)

      File.readlines(path).reverse_each do |line|
        parsed = JSON.parse(line)
        hash = parsed["event_hash"].to_s
        return hash if hash.match?(/\Asha256:[a-f0-9]{64}\z/)
      rescue JSON::ParserError
        next
      end
      nil
    rescue SystemCallError
      nil
    end

    def backend_event_hash(event)
      payload = event.reject { |key, _value| key == "event_hash" }
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(payload))}"
    end

    def backend_redact_event_value(value, depth = 0)
      Aiweb::Redaction.redact_event_value(value, depth: depth)
    end

    def backend_redact_event_text(value)
      Aiweb::Redaction.redact_event_text(value)
    end

    def backend_next_event_seq(path)
      File.file?(path) ? File.readlines(path).length + 1 : 1
    rescue SystemCallError
      1
    end

    def backend_engine_run_id(value, prefix: "engine-run")
      requested = value.to_s.strip
      unless requested.empty?
        safe = safe_run_id!(requested)
        unless safe.match?(/\Aengine-run-[A-Za-z0-9_.-]+\z/)
          raise UserError.new("engine-run job_run_id must start with engine-run- and contain only letters, numbers, dot, underscore, or dash", 1)
        end
        return safe
      end

      "#{prefix}-#{Time.now.utc.strftime("%Y%m%dT%H%M%S%6NZ")}"
    end

    def now_utc
      Time.now.utc.iso8601
    end
  end
end
