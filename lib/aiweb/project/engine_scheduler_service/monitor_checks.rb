# frozen_string_literal: true

module Aiweb
  module ProjectEngineSchedulerService
    private

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
  end
end
