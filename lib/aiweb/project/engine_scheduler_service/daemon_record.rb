# frozen_string_literal: true

module Aiweb
  module ProjectEngineSchedulerService
    private

    def engine_scheduler_daemon_record(target:, run_id:, approval_hash:, approved:, execute:, dry_run:, max_ticks:, interval_seconds:, workers:)
      tick_records = []
      service_records = []
      selected_run_id = nil
      stop_reason = nil
      tick_limit = dry_run ? 1 : max_ticks
      tick_index = 0
      loop do
        tick_index += 1
        service = engine_scheduler_service_record(action: "tick", target: target, approval_hash: approval_hash, approved: approved, execute: execute)
        service["daemon_driver"] = ENGINE_SCHEDULER_DAEMON_DRIVER
        service["daemon_tick_seq"] = tick_index
        selected_run_id ||= service["selected_run_id"]
        service_records << service
        tick_records << engine_scheduler_daemon_tick_summary(service, tick_index)

        stop_reason = engine_scheduler_daemon_stop_reason(service)
        break if stop_reason
        break if tick_limit.positive? && tick_index >= tick_limit

        sleep interval_seconds if interval_seconds.positive?
      end
      stop_reason ||= max_ticks.zero? ? "interrupted_or_unbounded_loop_exit" : "max_ticks_reached"
      blocking = []
      blocking << "engine scheduler daemon execute requires --approved" if execute && !approved
      blocking.concat(Array(service_records.last && service_records.last["blocking_issues"]))
      leases = engine_scheduler_daemon_leases(service_records, execute: execute)
      duplicate_claims = engine_scheduler_duplicate_active_lease_claims(leases)
      stale_recovered = engine_scheduler_stale_recovered_leases(leases)
      duplicate_claims.each { |claim| blocking << "engine scheduler daemon duplicate active lease blocked for #{claim["claim_key"]}" }
      blocking.uniq!
      status = blocking.empty? ? "recorded" : "blocked"
      status = "recorded" if blocking == ["engine scheduler has no selected engine run"]
      worker_pool = engine_scheduler_worker_pool_record(workers: workers, selected_run_id: selected_run_id, leases: leases)
      heartbeat = engine_scheduler_daemon_heartbeat(status: status, selected_run_id: selected_run_id, tick_count: tick_records.length, stop_reason: stop_reason, active_lease_count: leases.length)
      queue_events = engine_scheduler_daemon_queue_events(tick_records, leases, status, stale_recovered: stale_recovered)

      {
        "schema_version" => 1,
        "status" => status,
        "daemon_driver" => ENGINE_SCHEDULER_DAEMON_DRIVER,
        "service_driver" => ENGINE_SCHEDULER_SERVICE_DRIVER,
        "service_type" => "project_local_durable_graph_scheduler_daemon",
        "action" => "daemon",
        "decision" => status == "blocked" ? "blocked" : "daemon_recorded",
        "mode" => max_ticks.zero? ? "foreground_long_running_loop" : "foreground_bounded_loop",
        "run_selector" => run_id.to_s.strip.empty? ? "latest" : run_id.to_s.strip,
        "selected_run_id" => selected_run_id,
        "derived_start_node_id" => tick_records.last && tick_records.last["derived_start_node_id"],
        "approved" => approved == true,
        "execute" => execute == true,
        "dry_run" => dry_run == true,
        "max_ticks" => max_ticks,
        "interval_seconds" => interval_seconds,
        "workers" => workers,
        "tick_count" => tick_records.length,
        "stop_reason" => stop_reason,
        "daemon_artifact_path" => ENGINE_SCHEDULER_DAEMON_PATH,
        "heartbeat_path" => ENGINE_SCHEDULER_HEARTBEAT_PATH,
        "worker_pool_path" => ENGINE_SCHEDULER_WORKER_POOL_PATH,
        "leases_path" => ENGINE_SCHEDULER_LEASES_PATH,
        "queue_ledger_path" => ENGINE_SCHEDULER_QUEUE_LEDGER_PATH,
        "ledger_path" => ENGINE_SCHEDULER_LEDGER_PATH,
        "worker_pool" => worker_pool,
        "heartbeat" => heartbeat,
        "leases" => {
          "schema_version" => 1,
          "lease_driver" => ENGINE_SCHEDULER_WORKER_POOL_DRIVER,
          "status" => status,
          "active_lease_count" => leases.length,
          "leases" => leases,
          "duplicate_claims_blocked" => duplicate_claims,
          "stale_lease_recovery_policy" => "expired_or_ttl_elapsed_active_lease_may_be_reclaimed",
          "stale_lease_timeout_seconds" => ENGINE_SCHEDULER_LEASE_TTL_SECONDS,
          "stale_leases_recovered" => stale_recovered
        },
        "queue_events" => queue_events,
        "ticks" => tick_records,
        "service_records" => service_records,
        "blocking_issues" => blocking,
        "limitations" => [
          "project-local foreground daemon loop, not an OS service manager",
          "worker pool is a repo-local lease/slot contract, not a distributed cluster",
          "node bodies still execute through the engine-run resume bridge"
        ]
      }
    end
  end
end
