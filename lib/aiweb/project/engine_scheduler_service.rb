# frozen_string_literal: true

require_relative "engine_scheduler_service_domain"
require_relative "engine_scheduler_service/daemon_runtime"
require_relative "engine_scheduler_service/daemon_record"
require_relative "engine_scheduler_service/monitor"
require_relative "engine_scheduler_service/supervisor_record"

module Aiweb
  module ProjectEngineSchedulerService
    ENGINE_SCHEDULER_SERVICE_DRIVER = "aiweb.engine_scheduler.service.v1"
    ENGINE_SCHEDULER_DAEMON_DRIVER = "aiweb.engine_scheduler.daemon.v1"
    ENGINE_SCHEDULER_WORKER_POOL_DRIVER = "aiweb.engine_scheduler.worker_pool.v1"
    ENGINE_SCHEDULER_SUPERVISOR_DRIVER = "aiweb.engine_scheduler.supervisor.v1"
    ENGINE_SCHEDULER_MONITOR_DRIVER = "aiweb.engine_scheduler.monitor.v1"
    ENGINE_SCHEDULER_SERVICE_SCHEMA_VERSION = 1
    ENGINE_SCHEDULER_LEDGER_PATH = ".ai-web/scheduler/ledger.jsonl"
    ENGINE_SCHEDULER_DAEMON_PATH = ".ai-web/scheduler/daemon.json"
    ENGINE_SCHEDULER_HEARTBEAT_PATH = ".ai-web/scheduler/daemon-heartbeat.json"
    ENGINE_SCHEDULER_WORKER_POOL_PATH = ".ai-web/scheduler/worker-pool.json"
    ENGINE_SCHEDULER_LEASES_PATH = ".ai-web/scheduler/leases.json"
    ENGINE_SCHEDULER_QUEUE_LEDGER_PATH = ".ai-web/scheduler/queue-ledger.jsonl"
    ENGINE_SCHEDULER_SUPERVISOR_PATH = ".ai-web/scheduler/supervisor.json"
    ENGINE_SCHEDULER_MONITOR_PATH = ".ai-web/scheduler/monitor.json"
    ENGINE_SCHEDULER_LEASE_TTL_SECONDS = 300

    include Domain

    def engine_scheduler(action: "status", run_id: nil, approval_hash: nil, approved: false, execute: false, dry_run: false, force: false, max_ticks: 1, interval_seconds: 0, workers: 1, once: false)
      assert_initialized!
      normalized_action = action.to_s.strip.empty? ? "status" : action.to_s.strip
      unless %w[status tick daemon supervisor monitor].include?(normalized_action)
        raise UserError.new("engine-scheduler action must be status, tick, daemon, supervisor, or monitor", 1)
      end

      target = engine_scheduler_target(run_id)
      return engine_scheduler_monitor(dry_run: dry_run) if normalized_action == "monitor"

      if normalized_action == "supervisor"
        return engine_scheduler_supervisor(
          target: target,
          run_id: run_id,
          approval_hash: approval_hash,
          approved: approved,
          execute: execute,
          dry_run: dry_run,
          max_ticks: max_ticks,
          interval_seconds: interval_seconds,
          workers: workers,
          once: once
        )
      end
      if normalized_action == "daemon"
        return engine_scheduler_daemon(
          target: target,
          run_id: run_id,
          approval_hash: approval_hash,
          approved: approved,
          execute: execute,
          dry_run: dry_run,
          max_ticks: max_ticks,
          interval_seconds: interval_seconds,
          workers: workers,
          once: once
        )
      end

      service = engine_scheduler_service_record(action: normalized_action, target: target, approval_hash: approval_hash, approved: approved, execute: execute)
      service["status"] = "dry_run" if dry_run && normalized_action == "tick"

      if normalized_action == "status" || dry_run
        return engine_scheduler_payload(service, changed_files: [], dry_run: dry_run)
      end
      unless service["selected_run_id"]
        return engine_scheduler_payload(service, changed_files: [], dry_run: false)
      end

      if execute && approved && service["blocking_issues"].empty? && service["decision"] == "resume_ready"
        changes = engine_scheduler_attach_execution_result!(service)
      else
        changes = []
      end

      mutation(dry_run: false) do
        service_path = engine_scheduler_service_path(service.dig("selected_run", "run_id"))
        changes << write_json(service_path, service, false)
        changes << engine_scheduler_append_ledger(service)
      end

      engine_scheduler_payload(service, changed_files: compact_changes(changes), dry_run: false)
    end

    private

    def engine_scheduler_payload(service, changed_files:, dry_run:)
      {
        "schema_version" => 1,
        "current_phase" => load_state.dig("phase", "current"),
        "action_taken" => dry_run ? "planned engine scheduler tick" : engine_scheduler_action_taken(service),
        "changed_files" => changed_files.compact,
        "blocking_issues" => Array(service["blocking_issues"]),
        "engine_scheduler" => service,
        "next_action" => engine_scheduler_next_action(service)
      }
    end

    def engine_scheduler_daemon(target:, run_id:, approval_hash:, approved:, execute:, dry_run:, max_ticks:, interval_seconds:, workers:, once:)
      max_ticks = engine_scheduler_normalized_max_ticks(max_ticks, once: once)
      interval_seconds = engine_scheduler_normalized_interval_seconds(interval_seconds)
      workers = engine_scheduler_normalized_workers(workers)
      daemon = engine_scheduler_daemon_record(
        target: target,
        run_id: run_id,
        approval_hash: approval_hash,
        approved: approved,
        execute: execute,
        dry_run: dry_run,
        max_ticks: max_ticks,
        interval_seconds: interval_seconds,
        workers: workers
      )
      daemon["status"] = "dry_run" if dry_run
      changes = []
      unless dry_run
        mutation(dry_run: false) do
          changes << write_json(File.join(root, ENGINE_SCHEDULER_WORKER_POOL_PATH), daemon.fetch("worker_pool"), false)
          changes << write_json(File.join(root, ENGINE_SCHEDULER_HEARTBEAT_PATH), daemon.fetch("heartbeat"), false)
          changes << write_json(File.join(root, ENGINE_SCHEDULER_LEASES_PATH), daemon.fetch("leases"), false)
          Array(daemon["queue_events"]).each { |event| changes << engine_scheduler_append_queue_event(event) }
          next if engine_scheduler_daemon_execution_allowed?(daemon)

          Array(daemon["service_records"]).each do |service|
            next unless service["selected_run_id"]

            changes << write_json(engine_scheduler_service_path(service.fetch("selected_run_id")), service, false)
            changes << engine_scheduler_append_ledger(service)
          end
          changes << write_json(File.join(root, ENGINE_SCHEDULER_DAEMON_PATH), daemon, false)
        end

        if engine_scheduler_daemon_execution_allowed?(daemon)
          changes.concat(engine_scheduler_execute_daemon_services!(daemon))
          engine_scheduler_finalize_daemon_execution!(daemon)
          mutation(dry_run: false) do
            changes << write_json(File.join(root, ENGINE_SCHEDULER_WORKER_POOL_PATH), daemon.fetch("worker_pool"), false)
            changes << write_json(File.join(root, ENGINE_SCHEDULER_HEARTBEAT_PATH), daemon.fetch("heartbeat"), false)
            changes << write_json(File.join(root, ENGINE_SCHEDULER_LEASES_PATH), daemon.fetch("leases"), false)
            Array(daemon["execution_queue_events"]).each { |event| changes << engine_scheduler_append_queue_event(event) }
            Array(daemon["service_records"]).each do |service|
              next unless service["selected_run_id"]

              changes << write_json(engine_scheduler_service_path(service.fetch("selected_run_id")), service, false)
              changes << engine_scheduler_append_ledger(service)
            end
            changes << write_json(File.join(root, ENGINE_SCHEDULER_DAEMON_PATH), daemon, false)
          end
        end
      end

      {
        "schema_version" => 1,
        "current_phase" => load_state.dig("phase", "current"),
        "action_taken" => dry_run ? "planned engine scheduler daemon loop" : "recorded engine scheduler daemon loop",
        "changed_files" => compact_changes(changes),
        "blocking_issues" => Array(daemon["blocking_issues"]),
        "engine_scheduler" => daemon,
        "engine_scheduler_daemon" => daemon,
        "next_action" => engine_scheduler_daemon_next_action(daemon)
      }
    end

    def engine_scheduler_supervisor(target:, run_id:, approval_hash:, approved:, execute:, dry_run:, max_ticks:, interval_seconds:, workers:, once:)
      max_ticks = engine_scheduler_normalized_max_ticks(max_ticks, once: once)
      interval_seconds = engine_scheduler_normalized_interval_seconds(interval_seconds)
      workers = engine_scheduler_normalized_workers(workers)
      supervisor = engine_scheduler_supervisor_record(
        target: target,
        run_id: run_id,
        approval_hash: approval_hash,
        approved: approved,
        execute: execute,
        dry_run: dry_run,
        max_ticks: max_ticks,
        interval_seconds: interval_seconds,
        workers: workers
      )
      supervisor["status"] = "dry_run" if dry_run && supervisor["blocking_issues"].empty?
      changes = []
      unless dry_run
        mutation(dry_run: false) do
          changes << write_json(File.join(root, ENGINE_SCHEDULER_SUPERVISOR_PATH), supervisor, false)
        end
      end

      {
        "schema_version" => 1,
        "current_phase" => load_state.dig("phase", "current"),
        "action_taken" => dry_run ? "planned engine scheduler supervisor" : (supervisor["status"] == "blocked" ? "engine scheduler supervisor blocked" : "recorded engine scheduler supervisor"),
        "changed_files" => compact_changes(changes),
        "blocking_issues" => Array(supervisor["blocking_issues"]),
        "engine_scheduler" => supervisor,
        "engine_scheduler_supervisor" => supervisor,
        "next_action" => engine_scheduler_supervisor_next_action(supervisor)
      }
    end

  end
end
