# frozen_string_literal: true

module Aiweb
  module ProjectEngineSchedulerService
    def engine_scheduler_daemon_tick_summary(service, seq)
      service.slice("decision", "status", "selected_run_id", "derived_start_node_id", "terminal_run", "node_body_execution_mode", "execution_attempted", "execution_status", "execution_result_summary", "blocking_issues").merge(
        "seq" => seq,
        "recorded_at" => now
      )
    end

    def engine_scheduler_daemon_stop_reason(service)
      return "no_selected_run" if service["decision"] == "no_run"
      return "terminal_or_no_runnable_work" if service["decision"] == "noop_terminal"
      return "blocked" if service["decision"] == "blocked"
      return "resume_ready_deferred" if service["decision"] == "resume_ready" && service["execute"] != true
      return "resume_ready_execute_pending" if service["decision"] == "resume_ready" && service["execute"] == true

      nil
    end

    def engine_scheduler_daemon_execution_allowed?(daemon)
      daemon["execute"] == true &&
        daemon["approved"] == true &&
        daemon["status"] != "blocked" &&
        Array(daemon["service_records"]).any? { |service| engine_scheduler_service_executable?(service) }
    end

    def engine_scheduler_service_executable?(service)
      service["blocking_issues"].to_a.empty? && service["decision"] == "resume_ready"
    end

    def engine_scheduler_attach_execution_result!(service)
      service["execution_attempted"] = true
      service["execution_started_at"] = now
      result = engine_run(**engine_scheduler_resume_kwargs(service))
      service["execution_finished_at"] = now
      service["execution_result"] = result
      service["execution_result_summary"] = engine_scheduler_execution_result_summary(result)
      service["execution_status"] = service.dig("execution_result_summary", "status")
      Array(result["changed_files"]) + [service.dig("execution_result_summary", "metadata_path")]
    end

    def engine_scheduler_execution_result_summary(result)
      metadata = result.fetch("engine_run", {})
      checkpoint = metadata.fetch("checkpoint", {})
      {
        "run_id" => metadata["run_id"],
        "status" => metadata["status"],
        "metadata_path" => metadata["metadata_path"],
        "checkpoint_path" => metadata["checkpoint_path"],
        "graph_execution_plan_path" => metadata["graph_execution_plan_path"],
        "graph_scheduler_state_path" => metadata["graph_scheduler_state_path"],
        "resume_from" => checkpoint["resume_from"],
        "action_taken" => result["action_taken"],
        "blocking_issues" => Array(result["blocking_issues"])
      }
    end

    def engine_scheduler_execute_daemon_services!(daemon)
      Array(daemon["service_records"]).flat_map do |service|
        next [] unless engine_scheduler_service_executable?(service)

        engine_scheduler_attach_execution_result!(service)
      end
    end

    def engine_scheduler_finalize_daemon_execution!(daemon)
      executed_services = Array(daemon["service_records"]).select { |service| service["execution_attempted"] == true }
      return if executed_services.empty?

      summaries = executed_services.map { |service| service["execution_result_summary"].to_h }
      daemon["execution_attempted"] = true
      daemon["execution_status"] = summaries.all? { |summary| %w[passed no_changes].include?(summary["status"].to_s) } ? "completed" : "completed_with_nonpassing_status"
      daemon["execution_summary"] = {
        "service_count" => executed_services.length,
        "services" => summaries
      }
      daemon["stop_reason"] = "resume_ready_executed"
      daemon["ticks"] = Array(daemon["service_records"]).map.with_index do |service, index|
        engine_scheduler_daemon_tick_summary(service, service["daemon_tick_seq"] || index + 1)
      end
      engine_scheduler_finalize_daemon_leases!(daemon, executed_services)
      active_leases = engine_scheduler_active_daemon_leases(daemon.dig("leases", "leases"))
      daemon["leases"]["active_lease_count"] = active_leases.length
      daemon["worker_pool"] = engine_scheduler_worker_pool_record(workers: daemon["workers"], selected_run_id: daemon["selected_run_id"], leases: active_leases)
      daemon["heartbeat"] = engine_scheduler_daemon_heartbeat(status: daemon["status"], selected_run_id: daemon["selected_run_id"], tick_count: daemon["tick_count"], stop_reason: daemon["stop_reason"], active_lease_count: active_leases.length)
      daemon["execution_queue_events"] = engine_scheduler_daemon_execution_queue_events(executed_services)
      daemon["queue_events"] = Array(daemon["queue_events"]) + daemon["execution_queue_events"]
    end

    def engine_scheduler_finalize_daemon_leases!(daemon, executed_services)
      summaries_by_parent = executed_services.to_h do |service|
        [service["selected_run_id"].to_s, service["execution_result_summary"].to_h]
      end
      daemon["leases"]["leases"] = Array(daemon.dig("leases", "leases")).map do |lease|
        summary = summaries_by_parent[lease["run_id"].to_s]
        next lease unless summary

        status = summary["status"].to_s
        lease.merge(
          "state" => %w[passed no_changes].include?(status) ? "completed" : "execution_finished",
          "completed_at" => now,
          "execution_status" => status,
          "execution_run_id" => summary["run_id"],
          "execution_metadata_path" => summary["metadata_path"],
          "expires_at" => now
        )
      end
    end

    def engine_scheduler_active_daemon_leases(leases)
      Array(leases).select { |lease| %w[claimed_deferred running renewed].include?(lease["state"].to_s) }
    end

    def engine_scheduler_daemon_execution_queue_events(executed_services)
      Array(executed_services).map do |service|
        summary = service["execution_result_summary"].to_h
        {
          "schema_version" => 1,
          "event_type" => "scheduler.execution.finished",
          "status" => "recorded",
          "execution_status" => summary["status"],
          "run_id" => service["selected_run_id"],
          "execution_run_id" => summary["run_id"],
          "start_node_id" => service["derived_start_node_id"],
          "metadata_path" => summary["metadata_path"],
          "recorded_at" => now
        }
      end
    end

    def engine_scheduler_daemon_leases(service_records, execute:)
      seen = {}
      Array(service_records).filter_map do |service|
        next unless service["decision"] == "resume_ready"

        lease = service["lease"].to_h
        run_id = lease["run_id"].to_s
        start_node = lease["start_node_id"].to_s
        next if run_id.empty? || start_node.empty?

        claim_key = "#{run_id}:#{start_node}"
        next if seen[claim_key]

        seen[claim_key] = true
        {
          "lease_id" => lease["lease_id"],
          "claim_key" => claim_key,
          "run_id" => run_id,
          "start_node_id" => start_node,
          "state" => execute ? "running" : "claimed_deferred",
          "claimed_at" => now,
          "expires_at" => (Time.now.utc + ENGINE_SCHEDULER_LEASE_TTL_SECONDS).iso8601,
          "worker_slot_id" => nil,
          "duplicate_claim_prevented" => true
        }
      end
    end

    def engine_scheduler_duplicate_active_lease_claims(new_leases)
      active = engine_scheduler_existing_active_leases.reject { |lease| engine_scheduler_stale_lease?(lease) }
      active_keys = active.map { |lease| lease["claim_key"].to_s }.reject(&:empty?)
      Array(new_leases).select { |lease| active_keys.include?(lease["claim_key"].to_s) }
    end

    def engine_scheduler_stale_recovered_leases(new_leases)
      new_keys = Array(new_leases).map { |lease| lease["claim_key"].to_s }.reject(&:empty?)
      engine_scheduler_existing_active_leases.select do |lease|
        new_keys.include?(lease["claim_key"].to_s) && engine_scheduler_stale_lease?(lease)
      end.map do |lease|
        lease.merge(
          "state" => "expired",
          "recovered_at" => now,
          "recovery_reason" => "stale active lease expired before duplicate check"
        )
      end
    end

    def engine_scheduler_existing_active_leases
      existing = read_json_file(File.join(root, ENGINE_SCHEDULER_LEASES_PATH))
      Array(existing && existing["leases"]).select { |lease| %w[claimed_deferred running renewed].include?(lease["state"].to_s) }
    end

    def engine_scheduler_stale_lease?(lease)
      expires_at = engine_scheduler_parse_time(lease["expires_at"])
      return true if expires_at && expires_at <= Time.now.utc

      claimed_at = engine_scheduler_parse_time(lease["claimed_at"])
      return true if claimed_at && claimed_at <= Time.now.utc - ENGINE_SCHEDULER_LEASE_TTL_SECONDS

      false
    end

    def engine_scheduler_parse_time(value)
      return nil if value.to_s.strip.empty?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def engine_scheduler_daemon_queue_events(tick_records, leases, status, stale_recovered: [])
      tick_events = Array(tick_records).map do |tick|
        {
          "schema_version" => 1,
          "event_type" => "scheduler.tick",
          "status" => status,
          "run_id" => tick["selected_run_id"],
          "start_node_id" => tick["derived_start_node_id"],
          "decision" => tick["decision"],
          "recorded_at" => now
        }
      end
      lease_events = Array(leases).map do |lease|
        {
          "schema_version" => 1,
          "event_type" => "scheduler.lease.claimed",
          "status" => status,
          "claim_key" => lease["claim_key"],
          "lease_id" => lease["lease_id"],
          "run_id" => lease["run_id"],
          "start_node_id" => lease["start_node_id"],
          "worker_slot_id" => lease["worker_slot_id"],
          "recorded_at" => now
        }
      end
      stale_events = Array(stale_recovered).map do |lease|
        {
          "schema_version" => 1,
          "event_type" => "scheduler.lease.stale_recovered",
          "status" => status,
          "claim_key" => lease["claim_key"],
          "lease_id" => lease["lease_id"],
          "run_id" => lease["run_id"],
          "start_node_id" => lease["start_node_id"],
          "recorded_at" => now
        }
      end
      tick_events + stale_events + lease_events
    end

    def engine_scheduler_worker_pool_record(workers:, selected_run_id:, leases:)
      assigned_leases = Array(leases).each_with_index.map do |lease, index|
        lease.merge("worker_slot_id" => index < workers ? "local-worker-#{index + 1}" : nil)
      end
      {
        "schema_version" => 1,
        "pool_driver" => ENGINE_SCHEDULER_WORKER_POOL_DRIVER,
        "pool_type" => "project_local_scheduler_worker_pool_contract",
        "status" => "recorded",
        "max_workers" => workers,
        "selected_run_id" => selected_run_id,
        "active_lease_count" => assigned_leases.length,
        "concurrency_enforced" => assigned_leases.length <= workers,
        "queue_policy" => "explicit_or_latest_engine_run_only",
        "lease_policy" => "single_start_node_lease_per_run",
        "stale_lease_recovery_policy" => "expired_or_ttl_elapsed_active_lease_may_be_reclaimed",
        "lease_timeout_seconds" => ENGINE_SCHEDULER_LEASE_TTL_SECONDS,
        "executor" => "engine_run_resume_bridge",
        "distributed" => false,
        "worker_slots" => (1..workers).map do |index|
          lease = assigned_leases.find { |candidate| candidate["worker_slot_id"] == "local-worker-#{index}" }
          {
            "slot_id" => "local-worker-#{index}",
            "state" => lease ? (lease["state"] == "claimed_deferred" ? "claimed" : lease["state"]) : "available",
            "run_id" => lease && lease["run_id"],
            "lease_id" => lease && lease["lease_id"]
          }
        end,
        "active_leases" => assigned_leases,
        "limitations" => [
          "local process contract only",
          "no remote queue, autoscaling, or cross-host lease arbitration"
        ]
      }
    end

    def engine_scheduler_daemon_heartbeat(status:, selected_run_id:, tick_count:, stop_reason:, active_lease_count:)
      {
        "schema_version" => 1,
        "daemon_driver" => ENGINE_SCHEDULER_DAEMON_DRIVER,
        "status" => status,
        "pid" => Process.pid,
        "selected_run_id" => selected_run_id,
        "tick_count" => tick_count,
        "stop_reason" => stop_reason,
        "active_lease_count" => active_lease_count,
        "recorded_at" => now
      }
    end

    def engine_scheduler_append_queue_event(event)
      path = File.join(root, ENGINE_SCHEDULER_QUEUE_LEDGER_PATH)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "a") { |file| file.write(JSON.generate(event) + "\n") }
      ENGINE_SCHEDULER_QUEUE_LEDGER_PATH
    end

    def engine_scheduler_normalized_max_ticks(value, once:)
      return 1 if once

      ticks = Integer(value)
      raise UserError.new("engine-scheduler daemon --max-ticks must be between 0 and 1000", 1) unless ticks.between?(0, 1000)

      ticks
    rescue ArgumentError, TypeError
      raise UserError.new("engine-scheduler daemon --max-ticks must be an integer", 1)
    end

    def engine_scheduler_normalized_interval_seconds(value)
      seconds = Float(value)
      raise UserError.new("engine-scheduler daemon --interval-seconds must be between 0 and 60", 1) unless seconds >= 0 && seconds <= 60

      seconds
    rescue ArgumentError, TypeError
      raise UserError.new("engine-scheduler daemon --interval-seconds must be numeric", 1)
    end

    def engine_scheduler_normalized_workers(value)
      count = Integer(value)
      raise UserError.new("engine-scheduler daemon --workers must be between 1 and 16", 1) unless count.between?(1, 16)

      count
    rescue ArgumentError, TypeError
      raise UserError.new("engine-scheduler daemon --workers must be an integer", 1)
    end

    def engine_scheduler_daemon_next_action(daemon)
      return "inspect #{ENGINE_SCHEDULER_DAEMON_PATH}, #{ENGINE_SCHEDULER_WORKER_POOL_PATH}, and #{ENGINE_SCHEDULER_HEARTBEAT_PATH}" if daemon["status"] == "recorded"

      "inspect engine scheduler daemon blocking issues and latest service record"
    end

    def engine_scheduler_supervisor_next_action(supervisor)
      return "review #{ENGINE_SCHEDULER_SUPERVISOR_PATH}, then install the generated service unit manually only if operator privileges and authz boundaries are approved" if supervisor["status"] == "recorded"
      return "rerun aiweb engine-scheduler supervisor without --dry-run to record the supervisor artifact" if supervisor["status"] == "dry_run"

      "inspect engine scheduler supervisor blocking issues; aiweb intentionally does not install OS services"
    end

    def engine_scheduler_monitor_next_action(monitor)
      return "rerun aiweb engine-scheduler monitor without --dry-run to record #{ENGINE_SCHEDULER_MONITOR_PATH}" if monitor["status"] == "dry_run"
      return "inspect #{ENGINE_SCHEDULER_MONITOR_PATH}; scheduler artifacts are healthy" if monitor["health_status"] == "healthy"

      "inspect #{ENGINE_SCHEDULER_MONITOR_PATH}, #{ENGINE_SCHEDULER_HEARTBEAT_PATH}, #{ENGINE_SCHEDULER_LEASES_PATH}, and #{ENGINE_SCHEDULER_QUEUE_LEDGER_PATH}"
    end  end
end
