# frozen_string_literal: true

require_relative "monitor_checks"

module Aiweb
  module ProjectEngineSchedulerService
    def engine_scheduler_monitor(dry_run:)
      monitor = engine_scheduler_monitor_record(dry_run: dry_run)
      changes = []
      unless dry_run
        mutation(dry_run: false) do
          changes << write_json(File.join(root, ENGINE_SCHEDULER_MONITOR_PATH), monitor, false)
        end
      end
      {
        "schema_version" => 1,
        "current_phase" => load_state.dig("phase", "current"),
        "action_taken" => dry_run ? "planned engine scheduler monitor" : "recorded engine scheduler monitor",
        "changed_files" => compact_changes(changes),
        "blocking_issues" => Array(monitor["blocking_issues"]),
        "engine_scheduler" => monitor,
        "engine_scheduler_monitor" => monitor,
        "next_action" => engine_scheduler_monitor_next_action(monitor)
      }
    end

    def engine_scheduler_monitor_record(dry_run:)
      heartbeat = engine_scheduler_monitor_heartbeat_check
      leases = engine_scheduler_monitor_lease_check
      queue = engine_scheduler_monitor_queue_ledger_check
      worker_pool = engine_scheduler_monitor_worker_pool_check
      supervisor = engine_scheduler_monitor_supervisor_check
      checks = {
        "heartbeat" => heartbeat,
        "leases" => leases,
        "queue_ledger" => queue,
        "worker_pool" => worker_pool,
        "supervisor" => supervisor
      }
      blocking = []
      blocking << "engine scheduler heartbeat is missing" if heartbeat["status"] == "missing"
      blocking << "engine scheduler heartbeat is stale" if heartbeat["status"] == "stale"
      blocking << "engine scheduler active leases contain duplicate claim keys" if leases["duplicate_active_claim_count"].to_i.positive?
      blocking << "engine scheduler active leases contain stale claims" if leases["stale_active_lease_count"].to_i.positive?
      blocking << "engine scheduler queue ledger has parse errors" if queue["parse_error_count"].to_i.positive?
      blocking << "engine scheduler worker pool concurrency is not enforced" if worker_pool["concurrency_enforced"] == false
      health_status = if heartbeat["status"] == "missing" && worker_pool["status"] == "missing" && leases["status"] == "missing"
                        "missing"
                      elsif blocking.empty?
                        "healthy"
                      else
                        "degraded"
                      end
      {
        "schema_version" => 1,
        "status" => dry_run ? "dry_run" : "recorded",
        "health_status" => health_status,
        "monitor_driver" => ENGINE_SCHEDULER_MONITOR_DRIVER,
        "daemon_driver" => ENGINE_SCHEDULER_DAEMON_DRIVER,
        "worker_pool_driver" => ENGINE_SCHEDULER_WORKER_POOL_DRIVER,
        "supervisor_driver" => ENGINE_SCHEDULER_SUPERVISOR_DRIVER,
        "service_type" => "project_local_scheduler_monitor",
        "action" => "monitor",
        "dry_run" => dry_run == true,
        "monitor_artifact_path" => ENGINE_SCHEDULER_MONITOR_PATH,
        "recorded_at" => now,
        "checks" => checks,
        "production_readiness" => {
          "monitor_artifact_recorded" => dry_run != true,
          "os_service_health_observed" => false,
          "distributed_worker_cluster" => false,
          "remote_queue" => false,
          "node_body_executor" => "engine_run_resume_bridge"
        },
        "limitations" => [
          "monitors repo-local scheduler artifacts only",
          "does not inspect systemd, launchd, Windows Task Scheduler, or remote worker hosts",
          "does not turn the local lease contract into a distributed queue"
        ],
        "blocking_issues" => blocking
      }
    end

  end
end
