# frozen_string_literal: true

require_relative "agent_run_payload"
require_relative "dispatch_helpers"
require_relative "dispatch_adapter_helpers"
require_relative "dispatch/agent_runtime"
require_relative "dispatch/ops"

module Aiweb
  class CLI
    module Dispatch
      include AgentRunPayload
      include DispatchHelpers
      include DispatchAdapterHelpers

      private

    def dispatch(command)
      case command
      when "help", "--help", "-h"
        help_payload
      when "version", "--version"
        base_payload("version", "aiweb #{Aiweb::VERSION}")
      when "start"
        dispatch_start
      when "init"
        opts = parse_options do |o, options|
          o.on("--profile PROFILE") { |v| options[:profile] = v }
        end
        project.init(profile: opts[:profile], dry_run: @dry_run)
      when "status"
        project.status
      when *RUNTIME_PLAN_COMMANDS
        parse_options
        unless @argv.empty?
          raise UserError.new("#{command} does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.runtime_plan
      when "intent"
        dispatch_intent
      when *REGISTRY_COMMANDS
        dispatch_registry(command)
      when "interview"
        opts = parse_options do |o, options|
          o.on("--idea IDEA") { |v| options[:idea] = v }
        end
        opts[:idea] ||= @argv.join(" ")
        project.interview(idea: opts[:idea], dry_run: @dry_run)
      when "run"
        project.run(dry_run: @dry_run)
      when "run-status"
        dispatch_run_status
      when "run-timeline", "timeline"
        dispatch_run_timeline(command)
      when "observability-summary", "summary"
        dispatch_observability_summary(command)
      when "run-cancel"
        dispatch_run_cancel
      when "run-resume"
        dispatch_run_resume
      when "engine-run"
        dispatch_engine_run
      when "engine-scheduler"
        dispatch_engine_scheduler
      when "mcp-broker"
        dispatch_mcp_broker
      when "agent"
        dispatch_agent
      when "agent-run"
        dispatch_agent_run
      when "eval-baseline", "human-baseline"
        dispatch_eval_baseline
      when "verify-loop"
        dispatch_verify_loop
      when "design-brief"
        opts = parse_options do |o, options|
          o.on("--force") { options[:force] = true }
        end
        project.design_brief(dry_run: @dry_run, force: opts[:force])
      when "design-research"
        opts = parse_options do |o, options|
          o.on("--provider PROVIDER") { |v| options[:provider] = v }
          o.on("--policy POLICY") { |v| options[:policy] = v }
          o.on("--limit N") { |v| options[:limit] = v }
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("design-research does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.design_research(provider: opts[:provider] || "lazyweb", policy: opts[:policy], limit: opts[:limit] || 8, dry_run: @dry_run, force: opts[:force])
      when "design-system"
        dispatch_design_system
      when "design-prompt"
        opts = parse_options do |o, options|
          o.on("--force") { options[:force] = true }
        end
        project.design_prompt(dry_run: @dry_run, force: opts[:force])
      when "design"
        opts = parse_options do |o, options|
          o.on("--candidates N") { |v| options[:candidates] = v.to_i }
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("design does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.design(candidates: opts[:candidates] || 3, dry_run: @dry_run, force: opts[:force])
      when "select-design"
        parse_options
        selected = @argv.shift
        raise UserError.new("select-design requires a candidate id", EXIT_VALIDATION_FAILED) if selected.to_s.empty?
        unless @argv.empty?
          raise UserError.new("select-design does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.select_design(selected, dry_run: @dry_run)
      when "scaffold"
        opts = parse_options do |o, options|
          o.on("--profile PROFILE") { |v| options[:profile] = v }
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("scaffold does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.scaffold(profile: opts[:profile] || "D", dry_run: @dry_run, force: opts[:force])
      when "setup"
        dispatch_setup_command
      when "supabase-secret-qa"
        opts = parse_options do |o, options|
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("supabase-secret-qa does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.supabase_secret_qa(dry_run: @dry_run, force: opts[:force])
      when "supabase-local-verify"
        opts = parse_options do |o, options|
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("supabase-local-verify does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.supabase_local_verify(dry_run: @dry_run, force: opts[:force])
      when *RUNTIME_EXECUTION_COMMANDS
        dispatch_runtime_execution(command)
      when "visual-critique"
        opts = parse_options do |o, options|
          o.on("--screenshot PATH") { |v| options[:screenshot] = v }
          o.on("--metadata PATH") { |v| options[:metadata] = v }
          o.on("--from-screenshots VALUE") { |v| options[:from_screenshots] = v }
          o.on("--task-id ID") { |v| options[:task_id] = v }
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("visual-critique does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.visual_critique(screenshot: opts[:screenshot], metadata: opts[:metadata], from_screenshots: opts[:from_screenshots], task_id: opts[:task_id], force: opts[:force], dry_run: @dry_run)
      when "visual-polish"
        opts = parse_options do |o, options|
          o.on("--repair") { options[:repair] = true }
          o.on("--from-critique PATH_OR_LATEST") { |v| options[:from_critique] = v }
          o.on("--max-cycles N") { |v| options[:max_cycles] = parse_positive_integer(v, "--max-cycles") }
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("visual-polish does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        unless opts[:repair]
          raise UserError.new("visual-polish requires --repair for the bounded local repair loop", EXIT_VALIDATION_FAILED)
        end
        project.visual_polish(from_critique: opts[:from_critique] || "latest", max_cycles: opts[:max_cycles], force: opts[:force], dry_run: @dry_run)
      when "workbench"
        opts = parse_options do |o, options|
          o.on("--export") { options[:export] = true }
          o.on("--serve") { options[:serve] = true }
          o.on("--approval-hash HASH") { |v| options[:approval_hash] = v }
          o.on("--approval-request HASH") { |v| options[:approval_hash] = v }
          o.on("--approved") { options[:approved] = true }
          o.on("--host HOST") { |v| options[:host] = v }
          o.on("--port N") { |v| options[:port] = parse_positive_integer(v, "--port") }
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("workbench does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.workbench(export: opts[:export], serve: opts[:serve], approved: !!opts[:approved], approval_hash: opts[:approval_hash], host: opts[:host] || "127.0.0.1", port: opts[:port], force: opts[:force], dry_run: @dry_run)
      when "component-map"
        opts = parse_options do |o, options|
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("component-map does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.component_map(force: opts[:force], dry_run: @dry_run)
      when "visual-edit"
        opts = parse_options do |o, options|
          o.on("--target DATA_AIWEB_ID") { |v| options[:target] = v }
          o.on("--prompt TEXT") { |v| options[:prompt] = v }
          o.on("--from-map PATH_OR_LATEST") { |v| options[:from_map] = v }
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("visual-edit does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        if opts[:target].to_s.strip.empty?
          raise UserError.new("visual-edit requires --target DATA_AIWEB_ID", EXIT_VALIDATION_FAILED)
        end
        if opts[:prompt].to_s.strip.empty?
          raise UserError.new("visual-edit requires --prompt TEXT", EXIT_VALIDATION_FAILED)
        end
        project.visual_edit(target: opts[:target], prompt: opts[:prompt], from_map: opts[:from_map] || "latest", force: opts[:force], dry_run: @dry_run)
      when "github-sync"
        opts = parse_options do |o, options|
          o.on("--remote NAME") { |v| options[:remote] = v }
          o.on("--branch NAME") { |v| options[:branch] = v }
        end
        unless @argv.empty?
          raise UserError.new("github-sync does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end

        dispatch_github_sync(opts)
      when "deploy-plan"
        opts = parse_options do |o, options|
          o.on("--target TARGET") { |v| options[:target] = v }
        end
        unless @argv.empty?
          raise UserError.new("deploy-plan does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end

        dispatch_deploy_plan(opts)
      when "deploy"
        opts = parse_options do |o, options|
          o.on("--target TARGET") { |v| options[:target] = v }
          o.on("--approved") { options[:approved] = true }
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("deploy does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end

        dispatch_deploy(opts)
      when "daemon", "backend"
        opts = parse_options do |o, options|
          o.on("--host HOST") { |v| options[:host] = v }
          o.on("--port PORT") { |v| options[:port] = v }
        end
        unless @argv.empty?
          raise UserError.new("#{command} does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        host = opts[:host] || "127.0.0.1"
        port = opts[:port] || 4242
        if @dry_run
          Aiweb::LocalBackendDaemon.plan(host: host, port: port)
        else
          Aiweb::LocalBackendDaemon.new(host: host, port: port).start
          base_payload("daemon stopped", "local backend daemon stopped")
        end
      when "ingest-design"
        opts = parse_options do |o, options|
          o.on("--id ID") { |v| options[:id] = v }
          o.on("--title TITLE") { |v| options[:title] = v }
          o.on("--source SOURCE") { |v| options[:source] = v }
          o.on("--notes NOTES") { |v| options[:notes] = v }
          o.on("--selected") { options[:selected] = true }
          o.on("--force") { options[:force] = true }
        end
        project.ingest_design(id: opts[:id], title: opts[:title], source: opts[:source], notes: opts[:notes], selected: opts[:selected], dry_run: @dry_run, force: opts[:force])
      when "ingest-reference"
        opts = parse_options do |o, options|
          o.on("--type TYPE") { |v| options[:type] = v }
          o.on("--title TITLE") { |v| options[:title] = v }
          o.on("--source SOURCE") { |v| options[:source] = v }
          o.on("--notes NOTES") { |v| options[:notes] = v }
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("ingest-reference does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.ingest_reference(type: opts[:type], title: opts[:title], source: opts[:source], notes: opts[:notes], dry_run: @dry_run, force: opts[:force])
      when "next-task"
        opts = parse_options do |o, options|
          o.on("--type TYPE") { |v| options[:type] = v }
          o.on("--force") { options[:force] = true }
        end
        project.next_task(type: opts[:type], dry_run: @dry_run, force: opts[:force])
      when "qa-checklist"
        opts = parse_options do |o, options|
          o.on("--force") { options[:force] = true }
        end
        project.qa_checklist(dry_run: @dry_run, force: opts[:force])
      when "qa-report"
        opts = parse_options do |o, options|
          o.on("--from PATH") { |v| options[:from] = v }
          o.on("--status STATUS") { |v| options[:status] = v }
          o.on("--task-id ID") { |v| options[:task_id] = v }
          o.on("--duration-minutes N") { |v| options[:duration_minutes] = v.to_f }
          o.on("--timed-out") { options[:timed_out] = true }
          o.on("--force") { options[:force] = true }
        end
        project.qa_report(status: opts[:status] || "passed", task_id: opts[:task_id], duration_minutes: opts[:duration_minutes], timed_out: opts[:timed_out], from: opts[:from], dry_run: @dry_run, force: opts[:force])
      when "repair"
        opts = parse_options do |o, options|
          o.on("--from-qa PATH_OR_LATEST") { |v| options[:from_qa] = v }
          o.on("--max-cycles N") { |v| options[:max_cycles] = parse_positive_integer(v, "--max-cycles") }
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("repair does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.repair(from_qa: opts[:from_qa] || "latest", max_cycles: opts[:max_cycles], dry_run: @dry_run, force: opts[:force])
      when "advance"
        project.advance(dry_run: @dry_run)
      when "rollback"
        opts = parse_options do |o, options|
          o.on("--to PHASE") { |v| options[:to] = v }
          o.on("--failure CODE") { |v| options[:failure] = v }
          o.on("--reason REASON") { |v| options[:reason] = v }
        end
        if opts[:to].to_s.empty? && opts[:failure].to_s.empty?
          raise UserError.new("rollback requires --to or --failure", EXIT_VALIDATION_FAILED)
        end
        project.rollback(to: opts[:to], failure: opts[:failure], reason: opts[:reason], dry_run: @dry_run)
      when "resolve-blocker"
        opts = parse_options do |o, options|
          o.on("--reason REASON") { |v| options[:reason] = v }
        end
        project.resolve_blocker(reason: opts[:reason], dry_run: @dry_run)
      when "snapshot"
        opts = parse_options do |o, options|
          o.on("--reason REASON") { |v| options[:reason] = v }
        end
        project.snapshot(reason: opts[:reason], dry_run: @dry_run)
      else
        raise UserError.new("unknown command #{command.inspect}; run aiweb help", EXIT_VALIDATION_FAILED)
      end
    end

    def dispatch_start
      opts = parse_options do |o, options|
        o.on("--path PATH") { |v| options[:path] = v }
        o.on("--profile PROFILE") { |v| options[:profile] = v }
        o.on("--idea IDEA") { |v| options[:idea] = v }
        o.on("--no-advance") { options[:advance] = false }
      end
      opts[:idea] ||= @argv.join(" ")
      target_root = opts[:path].to_s.strip.empty? ? @root : File.expand_path(opts[:path])
      Project.new(target_root).start(idea: opts[:idea], profile: opts[:profile], advance: opts.fetch(:advance, true), dry_run: @dry_run)
    end

    def dispatch_run_status
      opts = parse_options do |o, options|
        o.on("--run-id ID") { |v| options[:run_id] = v }
      end
      reject_extra_args!("run-status")
      project.run_status(run_id: opts[:run_id])
    end

    def dispatch_run_timeline(command)
      opts = parse_options do |o, options|
        o.on("--limit N") { |v| options[:limit] = parse_positive_integer(v, "--limit") }
      end
      reject_extra_args!(command)
      project.run_timeline(limit: opts[:limit] || 20)
    end

    def dispatch_observability_summary(command)
      opts = parse_options do |o, options|
        o.on("--limit N") { |v| options[:limit] = parse_positive_integer(v, "--limit") }
      end
      reject_extra_args!(command)
      project.observability_summary(limit: opts[:limit] || 20)
    end

    def dispatch_run_cancel
      opts = parse_options do |o, options|
        o.on("--run-id ID") { |v| options[:run_id] = v }
        o.on("--force") { options[:force] = true }
      end
      reject_extra_args!("run-cancel")
      project.run_cancel(run_id: opts[:run_id] || "active", force: opts[:force], dry_run: @dry_run)
    end

    def dispatch_run_resume
      opts = parse_options do |o, options|
        o.on("--run-id ID") { |v| options[:run_id] = v }
      end
      reject_extra_args!("run-resume")
      project.run_resume(run_id: opts[:run_id] || "latest", dry_run: @dry_run)
    end

    def dispatch_verify_loop
      opts = parse_options do |o, options|
        o.on("--max-cycles N") { |v| options[:max_cycles] = parse_positive_integer(v, "--max-cycles") }
        o.on("--agent AGENT") { |v| options[:agent] = v }
        o.on("--sandbox SANDBOX") { |v| options[:sandbox] = v }
        o.on("--approval-hash HASH") { |v| options[:approval_hash] = v }
        o.on("--approved") { options[:approved] = true }
        o.on("--force") { options[:force] = true }
      end
      reject_extra_args!("verify-loop")
      project.verify_loop(max_cycles: opts[:max_cycles] || 3, agent: opts[:agent], sandbox: opts[:sandbox], approved: !!opts[:approved], approval_hash: opts[:approval_hash], force: opts[:force], dry_run: @dry_run)
    end

    def dispatch_intent
      subcommand = @argv.shift || "route"
      unless subcommand == "route"
        raise UserError.new("unknown intent command #{subcommand.inspect}; expected route", EXIT_VALIDATION_FAILED)
      end

      opts = parse_options do |o, options|
        o.on("--idea IDEA") { |v| options[:idea] = v }
      end
      if opts[:idea] && !@argv.empty?
        raise UserError.new("intent route does not accept extra positional arguments when --idea is provided: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
      end
      idea = opts[:idea] || @argv.join(" ")
      idea = IntentRouter.normalize_idea(idea)
      raise UserError.new("intent route requires --idea or a positional idea", EXIT_VALIDATION_FAILED) if idea.empty?

      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => "routed intent",
        "changed_files" => [],
        "blocking_issues" => [],
        "missing_artifacts" => [],
        "intent" => IntentRouter.route(idea),
        "next_action" => "use recommended_skill and recommended_design_system when drafting implementation artifacts"
      }
    end

    def dispatch_design_system
      subcommand = @argv.shift || "resolve"
      unless subcommand == "resolve"
        raise UserError.new("unknown design-system command #{subcommand.inspect}; expected resolve", EXIT_VALIDATION_FAILED)
      end

      opts = parse_options do |o, options|
        o.on("--force") { options[:force] = true }
      end
      unless @argv.empty?
        raise UserError.new("design-system resolve does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
      end

      project.design_system_resolve(dry_run: @dry_run, force: opts[:force])
    end


    def dispatch_runtime_execution(command)
      case command
      when "build"
        parse_options
        reject_extra_args!(command)
        project.build(dry_run: @dry_run)
      when "preview"
        opts = parse_options do |o, options|
          o.on("--stop") { options[:stop] = true }
        end
        reject_extra_args!(command)
        project.preview(dry_run: @dry_run, stop: opts[:stop])
      when "qa-playwright", "browser-qa"
        opts = parse_browser_qa_options(command)
        project.qa_playwright(url: opts[:url], task_id: opts[:task_id], force: opts[:force], dry_run: @dry_run)
      when "qa-screenshot", "screenshot-qa"
        opts = parse_browser_qa_options(command)
        project.qa_screenshot(url: opts[:url], task_id: opts[:task_id], force: opts[:force], dry_run: @dry_run)
      when "qa-a11y", "a11y-qa"
        opts = parse_browser_qa_options(command)
        project.qa_a11y(url: opts[:url], task_id: opts[:task_id], force: opts[:force], dry_run: @dry_run)
      when "qa-lighthouse", "lighthouse-qa"
        opts = parse_browser_qa_options(command)
        project.qa_lighthouse(url: opts[:url], task_id: opts[:task_id], force: opts[:force], dry_run: @dry_run)
      end
    end







    end
  end
end
