# frozen_string_literal: true

module Aiweb
  class CLI
    module Dispatch
      private

    def dispatch_agent_run
      opts = parse_options do |o, options|
        o.on("--task TASK") { |v| options[:task] = v }
        o.on("--agent AGENT") { |v| options[:agent] = v }
        o.on("--sandbox SANDBOX") { |v| options[:sandbox] = v }
        o.on("--approval-hash HASH") { |v| options[:approval_hash] = v }
        o.on("--approval-request HASH") { |v| options[:approval_hash] = v }
        o.on("--approved") { options[:approved] = true }
      end
      unless @argv.empty?
        raise UserError.new("agent-run does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
      end

      task = opts[:task].to_s.strip
      agent = opts[:agent].to_s.strip
      raise UserError.new("agent-run requires --task TASK", EXIT_UNSAFE_EXTERNAL_ACTION) if task.empty?
      raise UserError.new("agent-run requires --agent AGENT", EXIT_UNSAFE_EXTERNAL_ACTION) if agent.empty?
      sandbox = opts[:sandbox].to_s.strip.downcase
      raise UserError.new("agent-run --sandbox is only supported with --agent openmanus", EXIT_VALIDATION_FAILED) if !sandbox.empty? && agent != "openmanus"
      raise UserError.new("agent-run --sandbox must be docker or podman", EXIT_VALIDATION_FAILED) unless sandbox.empty? || %w[docker podman].include?(sandbox)

      approved = !!opts[:approved]
      return agent_run_approval_blocked_payload(task: task, agent: agent) if !@dry_run && !approved

      call_project_adapter(:agent_run, { task: task, agent: agent, sandbox: sandbox.empty? ? nil : sandbox, approved: approved, approval_hash: opts[:approval_hash], dry_run: @dry_run }).tap do |result|
        normalize_agent_run_payload!(result, task: task, agent: agent, approved: approved, dry_run: @dry_run)
      end
    end

    def dispatch_agent
      opts = parse_options do |o, options|
        o.on("--goal GOAL") { |v| options[:goal] = v }
        o.on("--mode MODE") { |v| options[:mode] = v }
        o.on("--profile PROFILE") { |v| options[:profile] = v }
        o.on("--max-steps N") { |v| options[:max_steps] = parse_positive_integer(v, "--max-steps") }
        o.on("--approval-hash HASH") { |v| options[:approval_hash] = v }
        o.on("--approval-request HASH") { |v| options[:approval_hash] = v }
        o.on("--approved") { options[:approved] = true }
      end
      opts[:goal] ||= @argv.join(" ")
      @argv.clear
      mode = opts[:mode].to_s.strip.empty? ? "plan-only" : opts[:mode].to_s.strip
      project.agent(
        goal: opts[:goal],
        mode: mode,
        profile: opts[:profile],
        max_steps: opts[:max_steps] || 20,
        approved: !!opts[:approved],
        approval_hash: opts[:approval_hash],
        dry_run: @dry_run
      )
    end

    def dispatch_eval_baseline
      subcommand = @argv.first.to_s.start_with?("-") ? "validate" : (@argv.shift || "validate")
      unless %w[validate import review-pack].include?(subcommand)
        raise UserError.new("unknown eval-baseline command #{subcommand.inspect}; expected validate, import, or review-pack", EXIT_VALIDATION_FAILED)
      end

      opts = parse_options do |o, options|
        o.on("--path PATH") { |v| options[:path] = v }
        o.on("--output PATH") { |v| options[:output] = v }
        o.on("--fixture-id ID") { |v| options[:fixture_id] = v }
        o.on("--approval-hash HASH") { |v| options[:approval_hash] = v }
        o.on("--approval-request HASH") { |v| options[:approval_hash] = v }
        o.on("--approved") { options[:approved] = true }
      end
      unless @argv.empty?
        raise UserError.new("eval-baseline #{subcommand} does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
      end

      project.eval_baseline(action: subcommand, source_path: opts[:path], output_path: opts[:output], fixture_id: opts[:fixture_id], approved: !!opts[:approved], approval_hash: opts[:approval_hash], dry_run: @dry_run)
    end

    def dispatch_engine_run
      opts = parse_options do |o, options|
        o.on("--goal GOAL") { |v| options[:goal] = v }
        o.on("--agent AGENT") { |v| options[:agent] = v }
        o.on("--mode MODE") { |v| options[:mode] = v }
        o.on("--sandbox SANDBOX") { |v| options[:sandbox] = v }
        o.on("--max-cycles N") { |v| options[:max_cycles] = parse_positive_integer(v, "--max-cycles") }
        o.on("--approval-hash HASH") { |v| options[:approval_hash] = v }
        o.on("--approval-request HASH") { |v| options[:approval_hash] = v }
        o.on("--resume RUN_ID") { |v| options[:resume] = v }
        o.on("--run-id RUN_ID") { |v| options[:run_id] = v }
        o.on("--approved") { options[:approved] = true }
        o.on("--force") { options[:force] = true }
      end
      opts[:goal] ||= @argv.join(" ")
      @argv.clear
      agent = opts[:agent].to_s.strip.empty? ? "codex" : opts[:agent].to_s.strip
      sandbox = opts[:sandbox].to_s.strip.downcase
      raise UserError.new("engine-run --sandbox is only supported with --agent openmanus, --agent openhands, --agent langgraph, or --agent openai_agents_sdk", EXIT_VALIDATION_FAILED) if !sandbox.empty? && !%w[openmanus openhands langgraph openai_agents_sdk].include?(agent)
      raise UserError.new("engine-run --sandbox must be docker or podman", EXIT_VALIDATION_FAILED) unless sandbox.empty? || %w[docker podman].include?(sandbox)

      call_project_adapter(:engine_run, {
        goal: opts[:goal],
        agent: agent,
        mode: opts[:mode] || "agentic_local",
        sandbox: sandbox.empty? ? nil : sandbox,
        max_cycles: opts[:max_cycles] || 3,
        approved: !!opts[:approved],
        approval_hash: opts[:approval_hash],
        resume: opts[:resume],
        run_id: opts[:run_id],
        force: opts[:force],
        dry_run: @dry_run
      })
    end

    def dispatch_engine_scheduler
      subcommand = @argv.first.to_s.start_with?("-") ? "status" : (@argv.shift || "status")
      unless %w[status tick daemon supervisor monitor].include?(subcommand)
        raise UserError.new("unknown engine-scheduler command #{subcommand.inspect}; expected status, tick, daemon, supervisor, or monitor", EXIT_VALIDATION_FAILED)
      end

      opts = parse_options do |o, options|
        o.on("--run-id ID") { |v| options[:run_id] = v }
        o.on("--approval-hash HASH") { |v| options[:approval_hash] = v }
        o.on("--approval-request HASH") { |v| options[:approval_hash] = v }
        o.on("--approved") { options[:approved] = true }
        o.on("--execute") { options[:execute] = true }
        o.on("--max-ticks N") { |v| options[:max_ticks] = v }
        o.on("--interval-seconds N") { |v| options[:interval_seconds] = v }
        o.on("--workers N") { |v| options[:workers] = v }
        o.on("--once") { options[:once] = true }
        o.on("--force") { options[:force] = true }
      end
      unless @argv.empty?
        raise UserError.new("engine-scheduler #{subcommand} does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
      end

      call_project_adapter(:engine_scheduler, {
        action: subcommand,
        run_id: opts[:run_id],
        approval_hash: opts[:approval_hash],
        approved: !!opts[:approved],
        execute: !!opts[:execute],
        max_ticks: opts[:max_ticks] || 1,
        interval_seconds: opts[:interval_seconds] || 0,
        workers: opts[:workers] || 1,
        once: !!opts[:once],
        force: opts[:force],
        dry_run: @dry_run
      })
    end

    def dispatch_mcp_broker
      subcommand = @argv.first.to_s.start_with?("-") ? "call" : (@argv.shift || "call")
      unless subcommand == "call"
        raise UserError.new("unknown mcp-broker command #{subcommand.inspect}; expected call", EXIT_VALIDATION_FAILED)
      end

      opts = parse_options do |o, options|
        o.on("--server SERVER") { |v| options[:server] = v }
        o.on("--tool TOOL") { |v| options[:tool] = v }
        o.on("--query QUERY") { |v| options[:query] = v }
        o.on("--limit N") { |v| options[:limit] = v }
        o.on("--endpoint URL") { |v| options[:endpoint] = v }
        o.on("--approval-hash HASH") { |v| options[:approval_hash] = v }
        o.on("--approval-request HASH") { |v| options[:approval_hash] = v }
        o.on("--approved") { options[:approved] = true }
        o.on("--force") { options[:force] = true }
      end
      unless @argv.empty?
        raise UserError.new("mcp-broker call does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
      end

      call_project_adapter(:mcp_broker, {
        action: subcommand,
        server: opts[:server],
        tool: opts[:tool],
        query: opts[:query],
        limit: opts[:limit] || 1,
        endpoint: opts[:endpoint],
        approved: !!opts[:approved],
        approval_hash: opts[:approval_hash],
        force: opts[:force],
        dry_run: @dry_run
      })
    end
    end
  end
end
