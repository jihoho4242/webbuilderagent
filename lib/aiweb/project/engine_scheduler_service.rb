# frozen_string_literal: true

require_relative "engine_scheduler_service_domain"
require_relative "engine_scheduler_service/daemon_runtime"
require_relative "engine_scheduler_service/monitor"

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

    def engine_scheduler_supervisor_record(target:, run_id:, approval_hash:, approved:, execute:, dry_run:, max_ticks:, interval_seconds:, workers:)
      selected_run = target && target["run_id"] ? run_lifecycle_record("run_id" => target.fetch("run_id")) : nil
      selected_run_id = selected_run && selected_run["run_id"]
      run_selector = run_id.to_s.strip.empty? ? "latest" : run_id.to_s.strip
      selected_metadata = selected_run_id ? (read_json_file(File.join(run_lifecycle_run_dir(selected_run_id), "engine-run.json")) || {}) : {}
      selected_resume_context = selected_run_id ? engine_run_resume_context(selected_run_id) : nil
      approval_evidence = selected_run_id ? engine_scheduler_resume_approval_evidence(selected_metadata, selected_run_id, selected_resume_context) : {}
      expected_approval_hash = approval_evidence["approval_hash"]
      supervisor_hash = approval_hash.to_s.strip.empty? ? (expected_approval_hash || "HASH") : approval_hash.to_s.strip
      daemon_argv = ["aiweb", "engine-scheduler", "daemon", "--max-ticks", max_ticks.to_s, "--interval-seconds", interval_seconds.to_s, "--workers", workers.to_s]
      daemon_argv.concat(["--run-id", selected_run_id]) if selected_run_id
      daemon_argv.concat(["--approval-hash", supervisor_hash])
      daemon_argv << "--approved"
      daemon_argv << "--execute"
      blocking = []
      blocking << "engine scheduler supervisor cannot install or execute OS service managers from aiweb; use generated artifacts for manual/operator install" if execute
      status = blocking.empty? ? "recorded" : "blocked"
      {
        "schema_version" => 1,
        "status" => status,
        "supervisor_driver" => ENGINE_SCHEDULER_SUPERVISOR_DRIVER,
        "daemon_driver" => ENGINE_SCHEDULER_DAEMON_DRIVER,
        "worker_pool_driver" => ENGINE_SCHEDULER_WORKER_POOL_DRIVER,
        "service_type" => "project_local_scheduler_supervisor_contract",
        "action" => "supervisor",
        "decision" => status == "blocked" ? "blocked" : "supervisor_plan_recorded",
        "run_selector" => run_selector,
        "selected_run_id" => selected_run_id,
        "approved" => approved == true,
        "expected_approval_hash" => expected_approval_hash,
        "approval_hash_derivation" => approval_evidence.empty? ? nil : approval_evidence,
        "execute" => execute == true,
        "dry_run" => dry_run == true,
        "install_performed" => false,
        "install_status" => "not_installed_by_aiweb",
        "supervisor_artifact_path" => ENGINE_SCHEDULER_SUPERVISOR_PATH,
        "daemon_artifact_path" => ENGINE_SCHEDULER_DAEMON_PATH,
        "heartbeat_path" => ENGINE_SCHEDULER_HEARTBEAT_PATH,
        "worker_pool_path" => ENGINE_SCHEDULER_WORKER_POOL_PATH,
        "leases_path" => ENGINE_SCHEDULER_LEASES_PATH,
        "queue_ledger_path" => ENGINE_SCHEDULER_QUEUE_LEDGER_PATH,
        "ledger_path" => ENGINE_SCHEDULER_LEDGER_PATH,
        "max_ticks" => max_ticks,
        "interval_seconds" => interval_seconds,
        "workers" => workers,
        "daemon_command" => {
          "argv" => daemon_argv,
          "working_directory" => ".",
          "operator_must_set_working_directory_to_project_root" => true,
          "approval_boundary" => "--approval-hash HASH --approved --execute resumes only through the engine-run bridge"
        },
        "restart_policy" => {
          "mode" => "external_supervisor_restart_on_failure",
          "restart" => "on_failure",
          "heartbeat_timeout_seconds" => ENGINE_SCHEDULER_LEASE_TTL_SECONDS,
          "lease_timeout_seconds" => ENGINE_SCHEDULER_LEASE_TTL_SECONDS,
          "max_backoff_seconds" => 60,
          "duplicate_claim_guard" => "leases.json duplicate active claim keys block restart; stale leases may be recovered after timeout"
        },
        "health_checks" => [
          {
            "name" => "heartbeat_recent",
            "path" => ENGINE_SCHEDULER_HEARTBEAT_PATH,
            "rule" => "recorded_at must be newer than heartbeat_timeout_seconds"
          },
          {
            "name" => "lease_staleness",
            "path" => ENGINE_SCHEDULER_LEASES_PATH,
            "rule" => "active leases older than lease_timeout_seconds are expired before duplicate checks"
          },
          {
            "name" => "queue_ledger_append_only",
            "path" => ENGINE_SCHEDULER_QUEUE_LEDGER_PATH,
            "rule" => "scheduler.tick and scheduler.lease.* events are append-only JSONL"
          }
        ],
        "service_unit_templates" => engine_scheduler_supervisor_unit_templates(daemon_argv),
        "operator_runbook" => [
          "review #{ENGINE_SCHEDULER_SUPERVISOR_PATH}",
          "install the matching service unit outside aiweb with operator privileges if desired",
          "keep working directory pinned to the project root",
          "monitor #{ENGINE_SCHEDULER_HEARTBEAT_PATH}, #{ENGINE_SCHEDULER_LEASES_PATH}, and #{ENGINE_SCHEDULER_QUEUE_LEDGER_PATH}",
          "do not expose scheduler control remotely without tenant/project/user authz"
        ],
        "production_readiness" => {
          "supervisor_contract_recorded" => true,
          "os_service_installed" => false,
          "distributed_worker_cluster" => false,
          "remote_queue" => false,
          "node_body_executor" => "engine_run_resume_bridge"
        },
        "limitations" => [
          "supervisor artifact only; aiweb does not install systemd, launchd, or Windows Task Scheduler services",
          "worker pool remains project-local lease/slot evidence, not a distributed cluster",
          "node bodies still execute through the engine-run resume bridge"
        ],
        "blocking_issues" => blocking
      }
    end

    def engine_scheduler_supervisor_unit_templates(daemon_argv)
      command = daemon_argv.join(" ")
      {
        "systemd_user_service" => [
          "[Unit]",
          "Description=aiweb engine scheduler daemon",
          "[Service]",
          "WorkingDirectory=<project-root>",
          "ExecStart=#{command}",
          "Restart=on-failure",
          "RestartSec=10",
          "[Install]",
          "WantedBy=default.target"
        ],
        "launchd_plist" => [
          "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
          "<plist version=\"1.0\"><dict>",
          "<key>Label</key><string>local.aiweb.engine-scheduler</string>",
          "<key>WorkingDirectory</key><string>&lt;project-root&gt;</string>",
          "<key>ProgramArguments</key><array>#{daemon_argv.map { |part| "<string>#{part}</string>" }.join}</array>",
          "<key>KeepAlive</key><true/>",
          "</dict></plist>"
        ],
        "windows_task_command" => "schtasks /Create /TN aiweb-engine-scheduler /SC ONSTART /TR \"#{command}\"",
        "portable_foreground_command" => command
      }
    end

  end
end
