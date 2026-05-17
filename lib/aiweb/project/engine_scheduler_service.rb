# frozen_string_literal: true

require_relative "engine_scheduler_service_domain"

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

    def engine_scheduler(action: "status", run_id: nil, approved: false, execute: false, dry_run: false, force: false, max_ticks: 1, interval_seconds: 0, workers: 1, once: false)
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
          approved: approved,
          execute: execute,
          dry_run: dry_run,
          max_ticks: max_ticks,
          interval_seconds: interval_seconds,
          workers: workers,
          once: once
        )
      end

      service = engine_scheduler_service_record(action: normalized_action, target: target, approved: approved, execute: execute)
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

    def engine_scheduler_daemon(target:, run_id:, approved:, execute:, dry_run:, max_ticks:, interval_seconds:, workers:, once:)
      max_ticks = engine_scheduler_normalized_max_ticks(max_ticks, once: once)
      interval_seconds = engine_scheduler_normalized_interval_seconds(interval_seconds)
      workers = engine_scheduler_normalized_workers(workers)
      daemon = engine_scheduler_daemon_record(
        target: target,
        run_id: run_id,
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

    def engine_scheduler_supervisor(target:, run_id:, approved:, execute:, dry_run:, max_ticks:, interval_seconds:, workers:, once:)
      max_ticks = engine_scheduler_normalized_max_ticks(max_ticks, once: once)
      interval_seconds = engine_scheduler_normalized_interval_seconds(interval_seconds)
      workers = engine_scheduler_normalized_workers(workers)
      supervisor = engine_scheduler_supervisor_record(
        target: target,
        run_id: run_id,
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

    def engine_scheduler_daemon_record(target:, run_id:, approved:, execute:, dry_run:, max_ticks:, interval_seconds:, workers:)
      tick_records = []
      service_records = []
      selected_run_id = nil
      stop_reason = nil
      tick_limit = dry_run ? 1 : max_ticks
      tick_index = 0
      loop do
        tick_index += 1
        service = engine_scheduler_service_record(action: "tick", target: target, approved: approved, execute: execute)
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

    def engine_scheduler_supervisor_record(target:, run_id:, approved:, execute:, dry_run:, max_ticks:, interval_seconds:, workers:)
      selected_run = target && target["run_id"] ? run_lifecycle_record("run_id" => target.fetch("run_id")) : nil
      selected_run_id = selected_run && selected_run["run_id"]
      run_selector = run_id.to_s.strip.empty? ? "latest" : run_id.to_s.strip
      daemon_argv = ["aiweb", "engine-scheduler", "daemon", "--max-ticks", max_ticks.to_s, "--interval-seconds", interval_seconds.to_s, "--workers", workers.to_s]
      daemon_argv.concat(["--run-id", selected_run_id]) if selected_run_id
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
          "approval_boundary" => "--approved --execute resumes only through engine-run bridge"
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

    def engine_scheduler_monitor_heartbeat_check
      heartbeat = read_json_file(File.join(root, ENGINE_SCHEDULER_HEARTBEAT_PATH))
      return { "path" => ENGINE_SCHEDULER_HEARTBEAT_PATH, "present" => false, "status" => "missing", "timeout_seconds" => ENGINE_SCHEDULER_LEASE_TTL_SECONDS } unless heartbeat.is_a?(Hash)

      recorded_at = engine_scheduler_parse_time(heartbeat["recorded_at"])
      age = recorded_at ? (Time.now.utc - recorded_at).round(3) : nil
      status = if recorded_at.nil?
                 "invalid"
               elsif age && age > ENGINE_SCHEDULER_LEASE_TTL_SECONDS
                 "stale"
               else
                 "fresh"
               end
      {
        "path" => ENGINE_SCHEDULER_HEARTBEAT_PATH,
        "present" => true,
        "status" => status,
        "recorded_at" => heartbeat["recorded_at"],
        "age_seconds" => age,
        "timeout_seconds" => ENGINE_SCHEDULER_LEASE_TTL_SECONDS,
        "pid" => heartbeat["pid"],
        "selected_run_id" => heartbeat["selected_run_id"],
        "stop_reason" => heartbeat["stop_reason"],
        "active_lease_count" => heartbeat["active_lease_count"]
      }
    end

    def engine_scheduler_monitor_lease_check
      leases_record = read_json_file(File.join(root, ENGINE_SCHEDULER_LEASES_PATH))
      return { "path" => ENGINE_SCHEDULER_LEASES_PATH, "present" => false, "status" => "missing", "active_lease_count" => 0, "stale_active_lease_count" => 0, "duplicate_active_claim_count" => 0 } unless leases_record.is_a?(Hash)

      leases = Array(leases_record["leases"])
      active = leases.select { |lease| %w[claimed_deferred running renewed].include?(lease["state"].to_s) }
      stale = active.select { |lease| engine_scheduler_stale_lease?(lease) }
      claim_counts = active.map { |lease| lease["claim_key"].to_s }.reject(&:empty?).tally
      duplicates = claim_counts.select { |_claim, count| count > 1 }.keys
      {
        "path" => ENGINE_SCHEDULER_LEASES_PATH,
        "present" => true,
        "status" => stale.empty? && duplicates.empty? ? "healthy" : "degraded",
        "active_lease_count" => active.length,
        "stale_active_lease_count" => stale.length,
        "duplicate_active_claim_count" => duplicates.length,
        "duplicate_claim_keys" => duplicates,
        "stale_claim_keys" => stale.map { |lease| lease["claim_key"] }.compact
      }
    end

    def engine_scheduler_monitor_queue_ledger_check
      path = File.join(root, ENGINE_SCHEDULER_QUEUE_LEDGER_PATH)
      return { "path" => ENGINE_SCHEDULER_QUEUE_LEDGER_PATH, "present" => false, "status" => "missing", "event_count" => 0, "parse_error_count" => 0 } unless File.file?(path)

      events = []
      parse_errors = 0
      File.readlines(path, chomp: true).each do |line|
        next if line.strip.empty?

        events << JSON.parse(line)
      rescue JSON::ParserError
        parse_errors += 1
      end
      last = events.last || {}
      {
        "path" => ENGINE_SCHEDULER_QUEUE_LEDGER_PATH,
        "present" => true,
        "status" => parse_errors.zero? ? "healthy" : "degraded",
        "event_count" => events.length,
        "parse_error_count" => parse_errors,
        "last_event_type" => last["event_type"],
        "last_recorded_at" => last["recorded_at"]
      }
    end

    def engine_scheduler_monitor_worker_pool_check
      pool = read_json_file(File.join(root, ENGINE_SCHEDULER_WORKER_POOL_PATH))
      return { "path" => ENGINE_SCHEDULER_WORKER_POOL_PATH, "present" => false, "status" => "missing", "concurrency_enforced" => nil } unless pool.is_a?(Hash)

      {
        "path" => ENGINE_SCHEDULER_WORKER_POOL_PATH,
        "present" => true,
        "status" => pool["concurrency_enforced"] == false ? "degraded" : "healthy",
        "pool_driver" => pool["pool_driver"],
        "max_workers" => pool["max_workers"],
        "active_lease_count" => pool["active_lease_count"],
        "concurrency_enforced" => pool["concurrency_enforced"],
        "distributed" => pool["distributed"]
      }
    end

    def engine_scheduler_monitor_supervisor_check
      supervisor = read_json_file(File.join(root, ENGINE_SCHEDULER_SUPERVISOR_PATH))
      return { "path" => ENGINE_SCHEDULER_SUPERVISOR_PATH, "present" => false, "status" => "missing", "os_service_installed_observed" => false } unless supervisor.is_a?(Hash)

      {
        "path" => ENGINE_SCHEDULER_SUPERVISOR_PATH,
        "present" => true,
        "status" => "contract_only",
        "install_status" => supervisor["install_status"],
        "install_performed" => supervisor["install_performed"],
        "os_service_installed_observed" => false,
        "supervisor_contract_recorded" => supervisor.dig("production_readiness", "supervisor_contract_recorded"),
        "distributed_worker_cluster" => supervisor.dig("production_readiness", "distributed_worker_cluster")
      }
    end

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
    end
  end
end
