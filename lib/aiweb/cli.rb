# frozen_string_literal: true

require "json"
require "optparse"
require "stringio"

require_relative "registry"
require_relative "intent_router"

module Aiweb
  class CLI
    EXIT_SUCCESS = 0
    EXIT_VALIDATION_FAILED = 1
    EXIT_PHASE_BLOCKED = 2
    EXIT_BUDGET_BLOCKED = 3
    EXIT_ADAPTER_UNAVAILABLE = 4
    EXIT_UNSAFE_EXTERNAL_ACTION = 5
    EXIT_INTERNAL_ERROR = 10

    MUTATION_COMMANDS = %w[start init interview run run-cancel run-resume agent-run verify-loop ingest-reference ingest-design next-task qa-checklist qa-report repair advance rollback resolve-blocker snapshot design-brief design-research design-system design-prompt design select-design scaffold setup build preview qa-playwright browser-qa qa-screenshot screenshot-qa qa-a11y a11y-qa qa-lighthouse lighthouse-qa visual-critique visual-polish workbench component-map visual-edit supabase-secret-qa supabase-local-verify github-sync deploy-plan deploy daemon backend].freeze
    RUNTIME_PLAN_COMMANDS = %w[runtime-plan scaffold-status].freeze
    REGISTRY_COMMANDS = %w[design-systems skills craft].freeze

    def initialize(argv, root)
      @argv = argv.dup
      @root = root
      @json = false
      @dry_run = false
    end

    def run
      parse_global_flags!
      if unsafe_env_path?(@root)
        return emit_error("unsafe project path blocked: .env/.env.* paths are not allowed", EXIT_UNSAFE_EXTERNAL_ACTION)
      end

      command = @argv.shift || "help"
      if @dry_run && !MUTATION_COMMANDS.include?(command)
        return emit_error("--dry-run is only supported for mutation commands", EXIT_VALIDATION_FAILED)
      end

      result = dispatch(command)
      result["dry_run"] = @dry_run if @dry_run
      emit_result(result)
      exit_code_for(command, result)
    rescue UserError => e
      emit_error(e.message, e.exit_code)
    rescue OptionParser::ParseError, ArgumentError => e
      emit_error(e.message, EXIT_VALIDATION_FAILED)
    rescue StandardError => e
      emit_error("#{e.class}: #{e.message}", EXIT_INTERNAL_ERROR)
    end

    private

    def project
      @project ||= Project.new(@root)
    end

    def registry
      @registry ||= Registry.new(@root)
    end

    def parse_global_flags!
      kept = []
      until @argv.empty?
        arg = @argv.shift
        case arg
        when "--json"
          @json = true
        when "--dry-run"
          @dry_run = true
        when "--path"
          value = @argv.shift
          raise OptionParser::MissingArgument, "--path" if value.to_s.empty?
          raise UserError.new("unsafe --path target blocked: .env/.env.* paths are not allowed", EXIT_UNSAFE_EXTERNAL_ACTION) if unsafe_env_path?(value)

          @root = File.expand_path(value)
        when /\A--path=(.+)\z/
          raise UserError.new("unsafe --path target blocked: .env/.env.* paths are not allowed", EXIT_UNSAFE_EXTERNAL_ACTION) if unsafe_env_path?($1)

          @root = File.expand_path($1)
        else
          kept << arg
        end
      end
      @argv = kept
    end

    def dispatch(command)
      case command
      when "help", "--help", "-h"
        help_payload
      when "version", "--version"
        base_payload("version", "aiweb #{Aiweb::VERSION}")
      when "start"
        opts = parse_options do |o, options|
          o.on("--path PATH") { |v| options[:path] = v }
          o.on("--profile PROFILE") { |v| options[:profile] = v }
          o.on("--idea IDEA") { |v| options[:idea] = v }
          o.on("--no-advance") { options[:advance] = false }
        end
        opts[:idea] ||= @argv.join(" ")
        target_root = opts[:path].to_s.strip.empty? ? @root : File.expand_path(opts[:path])
        Project.new(target_root).start(idea: opts[:idea], profile: opts[:profile], advance: opts.fetch(:advance, true), dry_run: @dry_run)
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
        opts = parse_options do |o, options|
          o.on("--run-id ID") { |v| options[:run_id] = v }
        end
        unless @argv.empty?
          raise UserError.new("run-status does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.run_status(run_id: opts[:run_id])
      when "run-timeline", "timeline"
        opts = parse_options do |o, options|
          o.on("--limit N") { |v| options[:limit] = parse_positive_integer(v, "--limit") }
        end
        unless @argv.empty?
          raise UserError.new("#{command} does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.run_timeline(limit: opts[:limit] || 20)
      when "observability-summary", "summary"
        opts = parse_options do |o, options|
          o.on("--limit N") { |v| options[:limit] = parse_positive_integer(v, "--limit") }
        end
        unless @argv.empty?
          raise UserError.new("#{command} does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.observability_summary(limit: opts[:limit] || 20)
      when "run-cancel"
        opts = parse_options do |o, options|
          o.on("--run-id ID") { |v| options[:run_id] = v }
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("run-cancel does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.run_cancel(run_id: opts[:run_id] || "active", force: opts[:force], dry_run: @dry_run)
      when "run-resume"
        opts = parse_options do |o, options|
          o.on("--run-id ID") { |v| options[:run_id] = v }
        end
        unless @argv.empty?
          raise UserError.new("run-resume does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.run_resume(run_id: opts[:run_id] || "latest", dry_run: @dry_run)
      when "agent-run"
        dispatch_agent_run
      when "verify-loop"
        opts = parse_options do |o, options|
          o.on("--max-cycles N") { |v| options[:max_cycles] = parse_positive_integer(v, "--max-cycles") }
          o.on("--approved") { options[:approved] = true }
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("verify-loop does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.verify_loop(max_cycles: opts[:max_cycles] || 3, approved: !!opts[:approved], force: opts[:force], dry_run: @dry_run)
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
        opts = parse_options do |o, options|
          o.on("--install") { options[:install] = true }
          o.on("--approved") { options[:approved] = true }
        end
        unless @argv.empty?
          raise UserError.new("setup does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        unless opts[:install]
          raise UserError.new("setup requires --install", EXIT_VALIDATION_FAILED)
        end

        dispatch_setup(opts)
      when "supabase-secret-qa"
        opts = parse_options do |o, options|
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("supabase-secret-qa does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        unless project.respond_to?(:supabase_secret_qa)
          return supabase_secret_qa_adapter_unavailable_payload(opts)
        end

        project.supabase_secret_qa(dry_run: @dry_run, force: opts[:force])
      when "supabase-local-verify"
        opts = parse_options do |o, options|
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("supabase-local-verify does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        unless project.respond_to?(:supabase_local_verify)
          return supabase_local_verify_adapter_unavailable_payload(opts)
        end

        project.supabase_local_verify(dry_run: @dry_run, force: opts[:force])
      when "build"
        parse_options
        unless @argv.empty?
          raise UserError.new("build does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.build(dry_run: @dry_run)
      when "preview"
        opts = parse_options do |o, options|
          o.on("--stop") { options[:stop] = true }
        end
        unless @argv.empty?
          raise UserError.new("preview does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.preview(dry_run: @dry_run, stop: opts[:stop])
      when "qa-playwright", "browser-qa"
        opts = parse_browser_qa_options(command)
        project.qa_playwright(url: opts[:url], task_id: opts[:task_id], force: opts[:force], dry_run: @dry_run)
      when "qa-screenshot", "screenshot-qa"
        opts = parse_browser_qa_options(command)
        return qa_screenshot_adapter_unavailable_payload(command, opts) unless project.respond_to?(:qa_screenshot)

        project.qa_screenshot(url: opts[:url], task_id: opts[:task_id], force: opts[:force], dry_run: @dry_run)
      when "qa-a11y", "a11y-qa"
        opts = parse_options do |o, options|
          o.on("--url URL") { |v| options[:url] = v }
          o.on("--task-id ID") { |v| options[:task_id] = v }
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("#{command} does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.qa_a11y(url: opts[:url], task_id: opts[:task_id], force: opts[:force], dry_run: @dry_run)
      when "qa-lighthouse", "lighthouse-qa"
        opts = parse_options do |o, options|
          o.on("--url URL") { |v| options[:url] = v }
          o.on("--task-id ID") { |v| options[:task_id] = v }
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("#{command} does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.qa_lighthouse(url: opts[:url], task_id: opts[:task_id], force: opts[:force], dry_run: @dry_run)
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
        unless project.respond_to?(:visual_critique)
          return visual_critique_adapter_unavailable_payload(opts)
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
        unless project.respond_to?(:visual_polish)
          return visual_polish_adapter_unavailable_payload(opts)
        end

        project.visual_polish(from_critique: opts[:from_critique] || "latest", max_cycles: opts[:max_cycles], force: opts[:force], dry_run: @dry_run)
      when "workbench"
        opts = parse_options do |o, options|
          o.on("--export") { options[:export] = true }
          o.on("--serve") { options[:serve] = true }
          o.on("--approved") { options[:approved] = true }
          o.on("--host HOST") { |v| options[:host] = v }
          o.on("--port N") { |v| options[:port] = parse_positive_integer(v, "--port") }
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("workbench does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        unless project.respond_to?(:workbench)
          return workbench_adapter_unavailable_payload(opts)
        end

        project.workbench(export: opts[:export], serve: opts[:serve], approved: !!opts[:approved], host: opts[:host] || "127.0.0.1", port: opts[:port], force: opts[:force], dry_run: @dry_run)
      when "component-map"
        opts = parse_options do |o, options|
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("component-map does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        unless project.respond_to?(:component_map)
          return component_map_adapter_unavailable_payload(opts)
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
        unless project.respond_to?(:visual_edit)
          return visual_edit_adapter_unavailable_payload(opts)
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

    def dispatch_registry(command)
      subcommand = @argv.shift || "list"
      unless subcommand == "list"
        raise UserError.new("unknown #{command} command #{subcommand.inspect}; expected list", EXIT_VALIDATION_FAILED)
      end

      parse_options
      unless @argv.empty?
        raise UserError.new("#{command} list does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
      end

      registry.list(command)
    end

    def parse_options
      options = {}
      parser = OptionParser.new do |o|
        yield(o, options) if block_given?
      end
      parser.parse!(@argv)
      options
    end

    def parse_positive_integer(value, option)
      text = value.to_s
      unless text.match?(/\A[1-9]\d*\z/)
        raise UserError.new("#{option} must be a positive integer", EXIT_VALIDATION_FAILED)
      end

      text.to_i
    end

    def relative_path(path)
      path = File.expand_path(path.to_s)
      root_prefix = @root.end_with?(File::SEPARATOR) ? @root : "#{@root}#{File::SEPARATOR}"
      return path.sub(root_prefix, "") if path.start_with?(root_prefix)

      path.sub(/\A#{Regexp.escape(@root)}\/?/, "")
    end

    def unsafe_env_path?(path)
      value = path.to_s.strip
      return false if value.empty? || value == "latest"

      File.basename(value).match?(/\A\.env(?:\.|\z)/)
    end

    def parse_browser_qa_options(command)
      opts = parse_options do |o, options|
        o.on("--url URL") { |v| options[:url] = v }
        o.on("--task-id ID") { |v| options[:task_id] = v }
        o.on("--force") { options[:force] = true }
      end
      unless @argv.empty?
        raise UserError.new("#{command} does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
      end
      opts
    end

    def dispatch_github_sync(opts)
      remote = opts[:remote].to_s.strip.empty? ? nil : opts[:remote].to_s.strip
      branch = opts[:branch].to_s.strip.empty? ? nil : opts[:branch].to_s.strip
      kwargs = { dry_run: @dry_run, remote: remote, branch: branch }.compact
      call_project_adapter(:github_sync, kwargs)
    end

    def dispatch_deploy_plan(opts)
      target = normalized_deploy_target_option(opts[:target], required: false, command: "deploy-plan")
      kwargs = { dry_run: @dry_run, target: target }.compact
      call_project_adapter(:deploy_plan, kwargs)
    end

    def dispatch_deploy(opts)
      target = normalized_deploy_target_option(opts[:target], required: true, command: "deploy")
      call_project_adapter(:deploy, { target: target, approved: !!opts[:approved], force: !!opts[:force], dry_run: @dry_run }).tap do |result|
        normalize_deploy_adapter_payload!(result, target)
      end
    rescue UserError => e
      raise unless unsafe_deploy_error?(e)

      unsafe_deploy_blocked_payload(target, e.message)
    end

    def dispatch_setup(opts)
      call_project_adapter(:setup, { install: true, approved: !!opts[:approved], dry_run: @dry_run }).tap do |result|
        normalize_setup_payload!(result, approved: !!opts[:approved], dry_run: @dry_run)
      end
    rescue UserError => e
      raise unless setup_approval_error?(e)

      setup_approval_blocked_payload(e.message)
    end

    def dispatch_agent_run
      opts = parse_options do |o, options|
        o.on("--task TASK") { |v| options[:task] = v }
        o.on("--agent AGENT") { |v| options[:agent] = v }
        o.on("--approved") { options[:approved] = true }
      end
      unless @argv.empty?
        raise UserError.new("agent-run does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
      end

      task = opts[:task].to_s.strip
      agent = opts[:agent].to_s.strip
      raise UserError.new("agent-run requires --task TASK", EXIT_UNSAFE_EXTERNAL_ACTION) if task.empty?
      raise UserError.new("agent-run requires --agent AGENT", EXIT_UNSAFE_EXTERNAL_ACTION) if agent.empty?

      approved = !!opts[:approved]
      return agent_run_approval_blocked_payload(task: task, agent: agent) if !@dry_run && !approved
      return agent_run_adapter_unavailable_payload(task: task, agent: agent, approved: approved) unless project.respond_to?(:agent_run)

      call_project_adapter(:agent_run, { task: task, agent: agent, approved: approved, dry_run: @dry_run }).tap do |result|
        normalize_agent_run_payload!(result, task: task, agent: agent, approved: approved, dry_run: @dry_run)
      end
    end

    def call_project_adapter(method_name, kwargs)
      unless project.respond_to?(method_name)
        raise UserError.new("#{method_name.to_s.tr("_", "-")} is not available for this project adapter", EXIT_ADAPTER_UNAVAILABLE)
      end

      project.public_send(method_name, **adapter_supported_kwargs(project.method(method_name), kwargs))
    end

    def adapter_supported_kwargs(method, kwargs)
      keyword_params = method.parameters.select { |kind, _| %i[key keyreq].include?(kind) }.map(&:last)
      return kwargs if keyword_params.empty?

      kwargs.select { |key, _| keyword_params.include?(key) }
    end

    def normalized_deploy_target_option(value, required:, command:)
      text = value.to_s.strip
      if text.empty?
        raise UserError.new("#{command} requires --target cloudflare-pages or --target vercel", EXIT_VALIDATION_FAILED) if required
        return nil
      end
      unless %w[cloudflare-pages vercel].include?(text)
        raise UserError.new("#{command} target must be cloudflare-pages or vercel", EXIT_VALIDATION_FAILED)
      end

      text
    end

    def normalize_deploy_adapter_payload!(result, target)
      return result unless result.is_a?(Hash)
      return result if result["deploy"].is_a?(Hash)

      dry_run_payload = result["deploy_dry_run"]
      return result unless dry_run_payload.is_a?(Hash)

      result["deploy"] = dry_run_payload.merge(
        "status" => dry_run_payload["status"] || "planned",
        "dry_run" => dry_run_payload.key?("dry_run") ? dry_run_payload["dry_run"] : true,
        "target" => dry_run_payload["target"] || target
      )
      result
    end

    def unsafe_deploy_error?(error)
      error.message.match?(/unsafe external action|unsafe deploy|blocked/i)
    end

    def setup_approval_error?(error)
      error.message.match?(/approved|approval|unsafe|blocked/i)
    end

    def normalize_setup_payload!(result, approved:, dry_run:)
      return result unless result.is_a?(Hash) && result["setup"].is_a?(Hash)

      setup = result["setup"]
      setup["requires_approval"] = !approved
      setup["approved"] = approved unless setup.key?("approved")
      setup["dry_run"] = dry_run unless setup.key?("dry_run")
      result
    end

    def normalize_agent_run_payload!(result, task:, agent:, approved:, dry_run:)
      return result unless result.is_a?(Hash) && result["agent_run"].is_a?(Hash)

      agent_run = result["agent_run"]
      agent_run["task"] ||= task
      agent_run["agent"] ||= agent
      agent_run["approved"] = approved unless agent_run.key?("approved")
      agent_run["dry_run"] = dry_run unless agent_run.key?("dry_run")
      result
    end

    def agent_run_base_payload(status:, task:, agent:, approved:, dry_run:, action_taken:, blocking_issues:, next_action:)
      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      run_id = "agent-run-#{timestamp}"
      run_dir = File.join(@root, ".ai-web", "runs", run_id)
      stdout_path = File.join(run_dir, "stdout.log")
      stderr_path = File.join(run_dir, "stderr.log")
      metadata_path = File.join(run_dir, "agent-run.json")
      diff_path = File.join(@root, ".ai-web", "diffs", "#{run_id}.patch")
      command = ["aiweb", "agent-run", "--task", task, "--agent", agent]
      command << "--approved" if approved
      command << "--dry-run" if dry_run

      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => action_taken,
        "changed_files" => dry_run ? [relative_path(run_dir), relative_path(stdout_path), relative_path(stderr_path), relative_path(metadata_path), relative_path(diff_path)] : [],
        "blocking_issues" => blocking_issues,
        "missing_artifacts" => [],
        "agent_run" => {
          "schema_version" => 1,
          "status" => status,
          "task" => task,
          "agent" => agent,
          "dry_run" => dry_run,
          "approved" => approved,
          "command" => command.join(" "),
          "planned_run_dir" => relative_path(run_dir),
          "planned_stdout_path" => relative_path(stdout_path),
          "planned_stderr_path" => relative_path(stderr_path),
          "planned_metadata_path" => relative_path(metadata_path),
          "planned_diff_path" => relative_path(diff_path),
          "guardrails" => [
            "--approved required for real local agent execution",
            "--dry-run writes nothing",
            "no build/preview/QA/deploy/provider CLI",
            "no .env/.env.* reads or output"
          ],
          "blocking_issues" => blocking_issues
        },
        "next_action" => next_action
      }
    end

    def agent_run_approval_blocked_payload(task:, agent:)
      agent_run_base_payload(
        status: "blocked",
        task: task,
        agent: agent,
        approved: false,
        dry_run: false,
        action_taken: "agent run blocked",
        blocking_issues: ["--approved is required for real local agent execution"],
        next_action: "rerun the agent run as aiweb agent-run --task #{task} --agent #{agent} --dry-run or --approved"
      )
    end

    def agent_run_dry_run_payload(task:, agent:, approved:)
      agent_run_base_payload(
        status: "dry_run",
        task: task,
        agent: agent,
        approved: approved,
        dry_run: true,
        action_taken: "planned agent run",
        blocking_issues: [],
        next_action: "rerun aiweb agent-run --task #{task} --agent #{agent} --approved to execute the local codex patch run"
      )
    end

    def agent_run_adapter_unavailable_payload(task:, agent:, approved:)
      agent_run_base_payload(
        status: "blocked",
        task: task,
        agent: agent,
        approved: approved,
        dry_run: false,
        action_taken: "agent run unavailable",
        blocking_issues: ["agent-run project adapter is not available in this build."],
        next_action: "integrate the local agent-run project adapter, then rerun the agent run as aiweb agent-run --task #{task} --agent #{agent} --approved"
      )
    end

    def unsafe_deploy_blocked_payload(target, message)
      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => "deploy blocked",
        "changed_files" => [],
        "blocking_issues" => ["unsafe deploy blocked: #{message}"],
        "missing_artifacts" => [],
        "deploy" => {
          "schema_version" => 1,
          "status" => "blocked",
          "dry_run" => false,
          "target" => target,
          "supported_targets" => %w[cloudflare-pages vercel],
          "guardrails" => ["no external deploy", "no provider CLI", "no network", "no build/preview/install", "no .env/.env.* access"],
          "blocking_issues" => ["unsafe deploy blocked: #{message}"]
        },
        "next_action" => "rerun as aiweb deploy --target cloudflare-pages|vercel --dry-run"
      }
    end

    def setup_approval_blocked_payload(message)
      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => "setup blocked",
        "changed_files" => [],
        "blocking_issues" => ["setup install approval required: #{message}"],
        "missing_artifacts" => [],
        "setup" => {
          "schema_version" => 1,
          "status" => "blocked",
          "dry_run" => false,
          "install" => true,
          "approved" => false,
          "planned_command" => "pnpm install",
          "planned_stdout_path" => ".ai-web/runs/setup-<timestamp>/stdout.log",
          "planned_stderr_path" => ".ai-web/runs/setup-<timestamp>/stderr.log",
          "planned_metadata_path" => ".ai-web/runs/setup-<timestamp>/setup.json",
          "guardrails" => ["--approved required for real install", "--dry-run writes nothing", "no build/preview/QA/deploy", "no .env/.env.* reads or output"],
          "blocking_issues" => ["setup install approval required: #{message}"]
        },
        "next_action" => "rerun as aiweb setup --install --dry-run or aiweb setup --install --approved"
      }
    end

    def supabase_secret_qa_adapter_unavailable_payload(opts)
      command_line = ["aiweb", "supabase-secret-qa"]
      command_line << "--force" if opts[:force]
      command_line << "--dry-run" if @dry_run

      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => "supabase secret QA unavailable",
        "changed_files" => [],
        "blocking_issues" => ["supabase-secret-qa command surface is reserved, but the project adapter is not implemented yet."],
        "missing_artifacts" => [],
        "supabase_secret_qa" => {
          "schema_version" => 1,
          "status" => "blocked",
          "dry_run" => @dry_run,
          "force" => !!opts[:force],
          "command" => command_line.join(" "),
          "planned_artifact_path" => ".ai-web/qa/supabase-secret-qa.json",
          "scanned_paths" => ["supabase/env.example.template"],
          "read_dot_env" => false,
          "guardrails" => ["no .env/.env.* reads", "no .env.example generation", "no external Supabase project creation", "no network/deploy/install/build/preview"],
          "blocking_issues" => ["supabase-secret-qa project adapter is not available in this build."]
        },
        "next_action" => "integrate the local Profile S Supabase secret QA project adapter, then rerun aiweb supabase-secret-qa --dry-run"
      }
    end

    def supabase_local_verify_adapter_unavailable_payload(opts)
      command_line = ["aiweb", "supabase-local-verify"]
      command_line << "--force" if opts[:force]
      command_line << "--dry-run" if @dry_run

      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => "supabase local verification unavailable",
        "changed_files" => [],
        "blocking_issues" => ["supabase-local-verify command surface is reserved, but the project adapter is not implemented yet."],
        "missing_artifacts" => [],
        "supabase_local_verify" => {
          "schema_version" => 1,
          "status" => "blocked",
          "dry_run" => @dry_run,
          "force" => !!opts[:force],
          "command" => command_line.join(" "),
          "planned_artifact_path" => ".ai-web/qa/supabase-local-verify.json",
          "read_dot_env" => false,
          "local_only" => true,
          "guardrails" => ["no .env/.env.* reads", "no external Supabase project creation", "no network/provider CLI/deploy/install/build/preview"],
          "blocking_issues" => ["supabase-local-verify project adapter is not available in this build."]
        },
        "next_action" => "integrate the local Profile S Supabase verification adapter, then rerun aiweb supabase-local-verify --dry-run"
      }
    end

    def visual_critique_adapter_unavailable_payload(opts)
      command_line = ["aiweb", "visual-critique"]
      command_line.concat(["--screenshot", opts[:screenshot].to_s]) unless opts[:screenshot].to_s.empty?
      command_line.concat(["--metadata", opts[:metadata].to_s]) unless opts[:metadata].to_s.empty?
      command_line.concat(["--task-id", opts[:task_id].to_s]) unless opts[:task_id].to_s.empty?
      command_line << "--force" if opts[:force]
      command_line << "--dry-run" if @dry_run

      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => "visual critique unavailable",
        "changed_files" => [],
        "blocking_issues" => ["visual-critique command surface is reserved, but the project adapter is not implemented yet."],
        "missing_artifacts" => [],
        "visual_critique" => {
          "schema_version" => 1,
          "status" => "blocked",
          "approval" => "repair",
          "command" => command_line.join(" "),
          "screenshot" => opts[:screenshot],
          "metadata" => opts[:metadata],
          "task_id" => opts[:task_id],
          "dry_run" => @dry_run,
          "blocking_issues" => ["visual-critique command surface is reserved, but the project adapter is not implemented yet."]
        },
        "next_action" => "implement the local visual critique project adapter, then rerun aiweb visual-critique"
      }
    end

    def visual_polish_adapter_unavailable_payload(opts)
      command_line = ["aiweb", "visual-polish", "--repair"]
      command_line.concat(["--from-critique", (opts[:from_critique] || "latest").to_s])
      command_line.concat(["--max-cycles", opts[:max_cycles].to_s]) if opts[:max_cycles]
      command_line << "--force" if opts[:force]
      command_line << "--dry-run" if @dry_run

      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => "visual polish unavailable",
        "changed_files" => [],
        "blocking_issues" => ["visual-polish command surface is reserved, but the project adapter is not implemented yet."],
        "missing_artifacts" => [],
        "visual_polish" => {
          "schema_version" => 1,
          "status" => "blocked",
          "mode" => "repair",
          "command" => command_line.join(" "),
          "from_critique" => opts[:from_critique] || "latest",
          "max_cycles" => opts[:max_cycles],
          "dry_run" => @dry_run,
          "blocking_issues" => ["visual-polish command surface is reserved, but the project adapter is not implemented yet."]
        },
        "next_action" => "implement the local visual polish project adapter, then rerun aiweb visual-polish --repair"
      }
    end

    def workbench_adapter_unavailable_payload(opts)
      command_line = ["aiweb", "workbench"]
      command_line << "--export" if opts[:export]
      command_line << "--force" if opts[:force]
      command_line << "--dry-run" if @dry_run

      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => "workbench unavailable",
        "changed_files" => [],
        "blocking_issues" => ["workbench command surface is reserved, but the project adapter is not implemented yet."],
        "missing_artifacts" => [],
        "workbench" => {
          "schema_version" => 1,
          "status" => "blocked",
          "dry_run" => @dry_run,
          "export" => !!opts[:export],
          "force" => !!opts[:force],
          "command" => command_line.join(" "),
          "panels" => %w[chat plan_artifacts design_candidates selected_design preview file_tree qa_results visual_critique run_timeline],
          "controls" => declarative_workbench_controls,
          "planned_index_path" => ".ai-web/workbench/index.html",
          "planned_manifest_path" => ".ai-web/workbench/workbench.json",
          "blocking_issues" => ["workbench project adapter is not available in this build."]
        },
        "next_action" => "integrate the local workbench project adapter, then rerun aiweb workbench --dry-run"
      }
    end

    def declarative_workbench_controls
      [
        "aiweb run",
        "aiweb design",
        "aiweb build",
        "aiweb preview",
        "aiweb qa-playwright",
        "aiweb visual-critique",
        "aiweb repair",
        "aiweb visual-polish",
        "aiweb component-map",
        "aiweb visual-edit --target DATA_AIWEB_ID --prompt TEXT"
      ].map do |command|
        {
          "command" => command,
          "mode" => "descriptor",
          "writes_state_directly" => false
        }
      end
    end

    def component_map_adapter_unavailable_payload(opts)
      command_line = ["aiweb", "component-map"]
      command_line << "--force" if opts[:force]
      command_line << "--dry-run" if @dry_run

      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => "component map unavailable",
        "changed_files" => [],
        "blocking_issues" => ["component-map command surface is reserved, but the project adapter is not implemented yet."],
        "missing_artifacts" => [],
        "component_map" => {
          "schema_version" => 1,
          "status" => "blocked",
          "dry_run" => @dry_run,
          "force" => !!opts[:force],
          "command" => command_line.join(" "),
          "planned_artifact_path" => ".ai-web/component-map.json",
          "components" => [],
          "blocking_issues" => ["component-map project adapter is not available in this build."]
        },
        "next_action" => "integrate the local component-map project adapter, then rerun aiweb component-map --dry-run"
      }
    end

    def visual_edit_adapter_unavailable_payload(opts)
      command_line = ["aiweb", "visual-edit", "--target", opts[:target].to_s, "--prompt", "TEXT"]
      command_line.concat(["--from-map", (opts[:from_map] || "latest").to_s])
      command_line << "--force" if opts[:force]
      command_line << "--dry-run" if @dry_run

      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => "visual edit unavailable",
        "changed_files" => [],
        "blocking_issues" => ["visual-edit command surface is reserved, but the project adapter is not implemented yet."],
        "missing_artifacts" => [],
        "visual_edit" => {
          "schema_version" => 1,
          "status" => "blocked",
          "dry_run" => @dry_run,
          "force" => !!opts[:force],
          "target" => opts[:target],
          "prompt_summary" => opts[:prompt].to_s.strip[0, 120],
          "from_map" => opts[:from_map] || "latest",
          "command" => command_line.join(" "),
          "planned_task_path" => ".ai-web/tasks/visual-edit-<timestamp>.md",
          "planned_record_path" => ".ai-web/visual/visual-edit-<timestamp>.json",
          "guardrails" => ["selected data-aiweb-id region only", "no source auto-patch", "no build/QA/browser/deploy/network/AI execution", "reject .env/.env.* map paths without reading"],
          "blocking_issues" => ["visual-edit project adapter is not available in this build."]
        },
        "next_action" => "integrate the local visual-edit project adapter, then rerun aiweb visual-edit --target DATA_AIWEB_ID --prompt TEXT --dry-run"
      }
    end

    def qa_screenshot_adapter_unavailable_payload(command, opts)
      target = opts[:url].to_s.strip
      command_line = ["aiweb", command]
      command_line.concat(["--url", target]) unless target.empty?
      command_line.concat(["--task-id", opts[:task_id].to_s]) unless opts[:task_id].to_s.empty?
      command_line << "--force" if opts[:force]
      command_line << "--dry-run" if @dry_run

      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => "screenshot QA unavailable",
        "changed_files" => [],
        "blocking_issues" => ["qa-screenshot command surface is reserved, but the screenshot QA project adapter is not implemented yet."],
        "missing_artifacts" => [],
        "screenshot_qa" => {
          "schema_version" => 1,
          "status" => "blocked",
          "command" => command_line.join(" "),
          "url" => target.empty? ? nil : target,
          "task_id" => opts[:task_id],
          "dry_run" => @dry_run,
          "planned_screenshots" => [
            ".ai-web/qa/screenshots/mobile-home.png",
            ".ai-web/qa/screenshots/tablet-home.png",
            ".ai-web/qa/screenshots/desktop-home.png"
          ],
          "planned_metadata_path" => ".ai-web/qa/screenshots/metadata.json",
          "blocking_issues" => ["qa-screenshot project adapter is not available in this build."]
        },
        "next_action" => "integrate the local qa-screenshot project adapter, then rerun aiweb qa-screenshot --url http://127.0.0.1:4321"
      }
    end

    def browser_adapter_unavailable_payload(command, opts)
      adapter = command.sub(/^qa-/, "")
      target = opts[:url].to_s.strip
      command_line = ["aiweb", command]
      command_line.concat(["--url", target]) unless target.empty?
      command_line.concat(["--task-id", opts[:task_id].to_s]) unless opts[:task_id].to_s.empty?
      command_line << "--force" if opts[:force]
      command_line << "--dry-run" if @dry_run

      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => "#{adapter} QA unavailable",
        "changed_files" => [],
        "blocking_issues" => ["#{command} command surface is reserved, but the #{adapter} QA adapter is not implemented yet."],
        "missing_artifacts" => [],
        "browser_qa" => {
          "schema_version" => 1,
          "adapter" => adapter,
          "status" => "blocked",
          "command" => command_line.join(" "),
          "url" => target.empty? ? nil : target,
          "task_id" => opts[:task_id],
          "dry_run" => @dry_run,
          "blocking_issues" => ["#{command} command surface is reserved, but the #{adapter} QA adapter is not implemented yet."]
        },
        "next_action" => "use aiweb qa-playwright for the implemented local browser QA path until #{command} has a project adapter"
      }
    end

    def help_payload
      base_payload("help", <<~HELP)
        aiweb — AI Web Director CLI

        Commands:
          start [--path PATH] --idea "..." [--profile A|B|C|D] [--no-advance]
          init [--profile A|B|C|D]
          status
          interview --idea "..."
          intent route --idea "..."
          run
          run-status [--run-id active|latest|ID]
          run-timeline [--limit N] (alias: timeline)
          observability-summary [--limit N] (alias: summary)
          run-cancel [--run-id active|ID] [--force]
          run-resume [--run-id latest|ID]
          design-brief [--force]
          design-research [--provider lazyweb] [--policy off|opportunistic|required] [--limit N] [--force]
          design-system resolve [--force]
          design-prompt [--force]
          design --candidates 3 [--force]
          select-design candidate-01|candidate-02|candidate-03
          scaffold --profile D [--force]
          scaffold --profile S [--force]
          setup --install --dry-run
          setup --install --approved
          supabase-secret-qa [--force]
          supabase-local-verify [--force]
          runtime-plan (alias: scaffold-status)
          build
          ingest-reference [--type manual|image|gpt-image-2|remote|lazyweb] [--title TITLE] [--source SOURCE] [--notes NOTES] [--force]
          ingest-design [--id ID] [--title TITLE] [--source SOURCE] [--notes NOTES] [--selected] [--force]
          next-task [--type TYPE] [--force]
          qa-checklist [--force]
          qa-report [--from PATH] [--status passed|failed|blocked] [--duration-minutes N] [--timed-out] [--force]
          repair [--from-qa PATH|latest] [--max-cycles N] [--force]
          verify-loop [--max-cycles N:1-10] [--approved] [--force]
          verify-loop --max-cycles 3 --dry-run
          verify-loop --max-cycles 3 --approved
          qa-playwright [--url URL] [--task-id ID] [--force]
          qa-screenshot [--url URL] [--task-id ID] [--force]
          qa-a11y [--url URL] [--task-id ID] [--force]
          qa-lighthouse [--url URL] [--task-id ID] [--force]
          visual-critique [--screenshot PATH] [--metadata PATH] [--from-screenshots latest] [--task-id ID] [--force]
          visual-polish --repair [--from-critique PATH|latest] [--max-cycles N] [--force]
          workbench [--export] [--serve] [--approved] [--host localhost|127.0.0.1] [--port N] [--force]
          workbench --serve --dry-run
          workbench --serve --approved
          daemon [--host 127.0.0.1] [--port 4242]
          component-map [--force]
          visual-edit --target DATA_AIWEB_ID --prompt TEXT [--from-map PATH|latest] [--force]
          github-sync [--remote NAME] [--branch NAME]
          deploy-plan [--target cloudflare-pages|vercel]
          deploy --target cloudflare-pages|vercel --dry-run
          deploy --target cloudflare-pages|vercel --approved
          advance
          rollback [--to PHASE] [--failure CODE] [--reason "..."]
          resolve-blocker --reason "..."
          snapshot [--reason "..."]
          design-systems list
          skills list
          craft list

        Global flags:
          --json       machine-readable output
          --dry-run    plan mutation without writing files
          --path PATH  run against a project directory

        Phase-sensitive commands are guarded:
          design-research: phase-3 or phase-3.5; --dry-run writes nothing and calls no network, real runs call Lazyweb only when configured, and implementation agents still receive no Lazyweb MCP/network access
          design-prompt: phase-3 or phase-3.5
          design: creates deterministic HTML design candidates without app scaffold
          select-design: records selected HTML candidate without overwriting DESIGN.md
          scaffold: creates Profile D Astro-style static app skeleton or Profile S local Next.js + Supabase SSR scaffold without installing packages, creating .env.example, contacting Supabase, deploying, or running build/preview
          setup --install: PR20 dependency install surface; --dry-run writes nothing and reports planned pnpm install/log paths, while a real install requires --approved, records stdout/stderr/setup metadata under .ai-web/runs/setup-<timestamp>/, warns on lifecycle scripts, updates safe setup state, and never builds/previews/runs QA/deploys or reads .env/.env.*
          supabase-secret-qa: reruns local-only Profile S secret guard QA against safe scaffold/template paths, including supabase/env.example.template, and records .ai-web/qa/supabase-secret-qa.json; --dry-run writes nothing and never reads .env/.env.*
          supabase-local-verify: verifies generated Profile S files, safe Supabase template, migrations/RLS/storage docs, and SSR client/server stubs locally, records .ai-web/qa/supabase-local-verify.json, and never creates hosted Supabase projects, runs provider CLI/network, deploys, installs, builds, previews, or reads .env/.env.*
          runtime-plan/scaffold-status: read-only runtime readiness metadata; does not install or launch Node
          run-status/run-cancel/run-resume: local run lifecycle control plane backed by .ai-web/runs/active-run.json plus per-run lifecycle/cancel/resume descriptors; status is read-only, cancel/resume support --dry-run no-write planning, cancellation is observed at lifecycle checkpoints, and resume records a descriptor without launching provider or agent commands
          run-timeline/observability-summary: read-only timeline and compact observability rollups over safe .ai-web/runs JSON evidence; caps --limit at 50, redacts secret-like keys and .env paths, writes nothing, and launches no processes
          build: runs the scaffolded Astro build only after runtime-plan is ready and records .ai-web/runs logs
          preview: starts/stops the local scaffold dev server after runtime-plan is ready; --dry-run does not write files or launch Node
          agent-run: runs an approved local source-patch agent task packet for repair / visual-polish / visual-edit evidence with logs and diff artifacts; --dry-run does not write files or launch a process
          qa-playwright: runs safe local Playwright QA browser checks against localhost/127.0.0.1 preview; --dry-run does not write files or launch Node
          qa-screenshot: captures safe local screenshot evidence for mobile/tablet/desktop from localhost/127.0.0.1 preview; --dry-run does not write files, launch browsers, install packages, or start preview
          qa-a11y: runs safe local axe accessibility QA against localhost/127.0.0.1 preview; --dry-run does not write files or launch Node
          qa-lighthouse: runs safe local Lighthouse QA against localhost/127.0.0.1 preview; --dry-run does not write files or launch Node
          visual-critique: records safe local visual critique from explicit screenshot/metadata evidence or --from-screenshots latest only; --dry-run plans .ai-web/visual artifacts without writes, browser launch, installs, repair, deploy, network, or .env access
          verify-loop: runs the local build -> preview -> QA -> critique -> task -> agent-run loop; --max-cycles is capped at 10, --dry-run writes nothing and plans build -> preview -> QA -> screenshot -> visual critique -> repair/visual-polish -> agent-run cycles, while real execution requires --approved, uses existing local adapters, records .ai-web/runs/verify-loop-<timestamp>/verify-loop.json plus per-cycle evidence and deploy provenance, never installs packages, never deploys, and stops on pass, max cycles, blockers, unsafe action, or agent-run failure
          agent-run --task latest --agent codex --dry-run
          agent-run --task latest --agent codex --approved
          workbench: plans, exports, or serves a local UI manifest under .ai-web/workbench using declarative CLI controls only; requires initialized .ai-web/state.yaml, --dry-run writes nothing, export writes only workbench artifacts, serve binds only localhost/127.0.0.1 and requires --approved for real process launch, executes no controls, and never mutates state.yaml
          daemon: starts the local backend API bridge for the future web Workbench; --dry-run reports endpoints and guardrails without binding a port
          ingest-reference: phase-3 or phase-3.5; writes only .ai-web/design-reference-brief.md pattern constraints, never implementation source, and rejects .env/.env.* or secret-looking reference paths
          component-map: scans stable data-aiweb-id regions into .ai-web/component-map.json; --dry-run writes nothing and never reads .env/.env.*
          visual-edit: validates a selected data-aiweb-id target and writes only local handoff artifacts; --dry-run writes nothing and never patches source, runs QA/browser/build, deploys, or calls network/AI
          github-sync: local-only GitHub sync planning surface; never runs git push, provider CLIs, network, build/preview/install, or reads .env/.env.*
          deploy-plan: local-only deploy checklist for Cloudflare Pages or Vercel; never runs provider CLIs, network, build/preview/install, or reads .env/.env.*
          deploy --target cloudflare-pages|vercel --dry-run: reports the deploy plan only without writes/processes; deploy --approved is gated by passing approved verify-loop evidence whose deploy provenance matches the current git/source/package/output/tool-version snapshot plus provider readiness, and records .ai-web/runs/deploy-* evidence before any provider adapter command can run
          ingest-design: phase-3.5
          next-task: phase-6 through phase-11
          qa-checklist: phase-7 through phase-11
          qa-report: phase-7 through phase-11
          repair: phase-7 through phase-11; records a bounded local repair-loop task from failed/blocked QA without running build, QA, preview, deploy, package install, or source auto-patches
          agent-run: phase-7 through phase-11; approved local source-patch task packets only, with logs, diff evidence, and no .env/.env.* access
          qa-screenshot: phase-7 through phase-11; captures safe local screenshot evidence for critique/human QA without starting preview or installing packages
          visual-critique: phase-7 through phase-11; records deterministic local visual critique evidence from explicit input paths or latest screenshot metadata only
          visual-polish --repair: records safe local visual polish repair loop from failed/repair/redesign critique evidence in phase-7 through phase-11 without source edits, build, QA, preview, browser capture, deploy, package install, network, or AI calls
          component-map / visual-edit: phase-7 through phase-11; map stable DOM regions and create selected-region visual edit handoff records without source auto-patches or external execution
          Profile S: local scaffold/QA only; Supabase SSR placeholders are NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY in supabase/env.example.template, supabase-local-verify records local evidence at .ai-web/qa/supabase-local-verify.json, and .env.example is intentionally not generated under the no-.env guardrail
        Use --force only for manual repair/override.
      HELP
    end

    def base_payload(action, message)
      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => action,
        "changed_files" => [],
        "blocking_issues" => [],
        "missing_artifacts" => [],
        "next_action" => message
      }
    end

    def emit_result(result)
      if @json
        puts JSON.pretty_generate(result)
      else
        puts human_result(result)
      end
    end

    def emit_error(message, code)
      payload = {
        "schema_version" => 1,
        "status" => "error",
        "error" => { "code" => code, "message" => message },
        "blocking_issues" => [message],
        "next_action" => "fix the reported issue and rerun the command"
      }
      if @json
        puts JSON.pretty_generate(payload)
      else
        warn "Error: #{message}"
        warn "Next command: #{payload["next_action"]}"
      end
      code
    end

    def human_result(result)
      return human_registry_result(result) if result["registry"]
      return human_intent_result(result) if result["intent"]
      return human_runtime_plan_result(result) if result["runtime_plan"]
      return human_verify_loop_result(result) if result["verify_loop"]
      return human_agent_run_result(result) if result["agent_run"]
      return human_repair_result(result) if result["repair_loop"]
      return human_qa_screenshot_result(result) if result["screenshot_qa"]
      return human_visual_critique_result(result) if result["visual_critique"]
      return human_visual_polish_result(result) if result["visual_polish"]
      return human_workbench_result(result) if result["workbench"]
      return human_component_map_result(result) if result["component_map"]
      return human_visual_edit_result(result) if result["visual_edit"]
      return human_supabase_local_verify_result(result) if result["supabase_local_verify"]
      return human_supabase_secret_qa_result(result) if result["supabase_secret_qa"]
      return human_setup_result(result) if result["setup"]
      return human_run_timeline_result(result) if result["run_timeline"]
      return human_observability_summary_result(result) if result["observability_summary"]
      return human_run_lifecycle_result(result) if result["run_lifecycle"]

      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = result["blocking_issues"] || []
      [
        "Current phase: #{result["current_phase"] || "n/a"}",
        "Action taken: #{result["action_taken"] || "n/a"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_run_lifecycle_result(result)
      lifecycle = result.fetch("run_lifecycle")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = lifecycle["blocking_issues"] || result["blocking_issues"] || []
      active = lifecycle["active_run"]
      selected = lifecycle["selected_run"]
      [
        "Run lifecycle: #{lifecycle["status"] || "n/a"}",
        "Active run: #{active ? "#{active["run_id"]} (#{active["kind"] || "unknown"})" : "none"}",
        "Selected run: #{selected ? "#{selected["run_id"]} (#{selected["kind"] || "unknown"})" : "none"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_run_timeline_result(result)
      timeline = result.fetch("run_timeline")
      runs = Array(timeline["runs"])
      blockers = timeline["blocking_issues"] || result["blocking_issues"] || []
      [
        "Run timeline: #{timeline["status"] || "n/a"}",
        "Limit: #{timeline["limit"] || "n/a"}",
        "Runs: #{runs.length}",
        "Latest: #{runs.last ? runs.last["path"] : "none"}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_observability_summary_result(result)
      summary = result.fetch("observability_summary")
      blockers = summary["blocking_issues"] || result["blocking_issues"] || []
      counts = summary["recent_status_counts"].is_a?(Hash) ? summary["recent_status_counts"].map { |k, v| "#{k}=#{v}" }.join(", ") : "none"
      [
        "Observability: #{summary["status"] || "n/a"}",
        "Active run: #{summary["active_run"] ? summary["active_run"]["run_id"] : "none"}",
        "Recent runs: #{summary["recent_run_count"] || 0}",
        "Status counts: #{counts.empty? ? "none" : counts}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_intent_result(result)
      intent = result.fetch("intent")
      lines = [
        "Intent route",
        "- Archetype: #{intent.fetch("archetype")}",
        "- Surface: #{intent.fetch("surface")}",
        "- Recommended skill: #{intent.fetch("recommended_skill")}",
        "- Recommended design system: #{intent.fetch("recommended_design_system")}",
        "- Recommended profile: #{intent.fetch("recommended_profile")}",
        "- Framework: #{intent.fetch("framework")}",
        "- Safety sensitive: #{intent.fetch("safety_sensitive")}",
        "- Style keywords: #{intent.fetch("style_keywords").join(", ")}",
        "- Forbidden design patterns: #{intent.fetch("forbidden_design_patterns").join("; ")}"
      ]
      lines.join("\n")
    end

    def human_supabase_secret_qa_result(result)
      qa = result.fetch("supabase_secret_qa")
      blockers = qa["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[artifact_path planned_artifact_path].each do |key|
        value = qa[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Supabase secret QA: #{qa["status"] || "n/a"}",
        "Dry run: #{qa.key?("dry_run") ? qa["dry_run"] : "n/a"}",
        "Read .env: #{qa.key?("read_dot_env") ? qa["read_dot_env"] : false}",
        "Scanned paths: #{Array(qa["scanned_paths"]).empty? ? "none" : Array(qa["scanned_paths"]).join(", ")}",
        "Artifacts: #{paths.empty? ? "none" : paths.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_supabase_local_verify_result(result)
      verify = result.fetch("supabase_local_verify")
      blockers = verify["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[artifact_path planned_artifact_path].each do |key|
        value = verify[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Supabase local verify: #{verify["status"] || "n/a"}",
        "Dry run: #{verify.key?("dry_run") ? verify["dry_run"] : "n/a"}",
        "Read .env: #{verify.key?("read_dot_env") ? verify["read_dot_env"] : false}",
        "External actions performed: #{verify.key?("external_actions_performed") ? verify["external_actions_performed"] : false}",
        "Scanned paths: #{Array(verify["scanned_paths"]).empty? ? "none" : Array(verify["scanned_paths"]).join(", ")}",
        "Artifacts: #{paths.empty? ? "none" : paths.join(", ")}",
        "Findings: #{Array(verify["findings"]).empty? ? "none" : Array(verify["findings"]).map { |finding| finding["message"] || finding.to_s }.join("; ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_setup_result(result)
      setup = result.fetch("setup")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = setup["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[run_dir stdout_path stderr_path metadata_path setup_json_path planned_run_dir planned_stdout_path planned_stderr_path planned_metadata_path planned_setup_json_path].each do |key|
        value = setup[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Setup install: #{setup["status"] || "n/a"}",
        "Package manager: #{setup["package_manager"] || "n/a"}",
        "Dry run: #{setup.key?("dry_run") ? setup["dry_run"] : "n/a"}",
        "Approved: #{setup.key?("approved") ? setup["approved"] : "n/a"}",
        "Command: #{setup["command"] || setup["planned_command"] || "n/a"}",
        "Lifecycle scripts: #{Array(setup["lifecycle_scripts"] || setup["lifecycle_script_warnings"]).empty? ? "none" : Array(setup["lifecycle_scripts"] || setup["lifecycle_script_warnings"]).join(", ")}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Setup paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_qa_screenshot_result(result)
      qa = result.fetch("screenshot_qa")
      blockers = qa["blocking_issues"] || result["blocking_issues"] || []
      screenshots = qa["screenshots"] || qa["screenshot_paths"] || []
      artifacts = []
      %w[metadata_path result_path run_dir stdout_log stderr_log].each do |key|
        value = qa[key]
        artifacts << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Screenshot QA: #{qa["status"] || "n/a"}",
        "Target URL: #{qa["url"] || qa.dig("target", "url") || "n/a"}",
        "Screenshots: #{Array(screenshots).empty? ? "none" : Array(screenshots).join(", ")}",
        "Artifacts: #{artifacts.empty? ? "none" : artifacts.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_visual_critique_result(result)
      critique = result.fetch("visual_critique")
      scores = critique["scores"] || {}
      score_line = if scores.empty?
        "Scores: n/a"
      else
        ordered = %w[hierarchy typography spacing color originality mobile_polish brand_fit intent_fit]
        "Scores: " + ordered.select { |key| scores.key?(key) }.map { |key| "#{key}=#{scores[key]}" }.join(", ")
      end
      issues = critique["issues"] || []
      plan = critique["patch_plan"] || []
      paths = []
      %w[artifact_path planned_artifact_path screenshot metadata].each do |key|
        value = critique[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Visual critique: #{critique["status"] || "n/a"}",
        "Approval: #{critique["approval"] || "n/a"}",
        score_line,
        "Evidence: #{paths.empty? ? "none" : paths.join(", ")}",
        "Issues: #{issues.empty? ? "none" : issues.join("; ")}",
        "Patch plan: #{plan.empty? ? "none" : plan.join("; ")}",
        "Blocking issues: #{(result["blocking_issues"] || critique["blocking_issues"] || []).empty? ? "none" : (result["blocking_issues"] || critique["blocking_issues"]).join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_visual_polish_result(result)
      polish = result.fetch("visual_polish")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = polish["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[polish_record_path visual_polish_record_path record_path snapshot_path pre_polish_snapshot polish_task_path task_path planned_polish_record_path planned_visual_polish_record_path planned_record_path planned_snapshot_path planned_polish_task_path planned_task_path].each do |key|
        value = polish[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Visual polish: #{polish["status"] || "n/a"}",
        "Mode: #{polish["mode"] || (polish["repair"] ? "repair" : "n/a")}",
        "Critique source: #{polish["critique_source"] || polish["from_critique"] || "n/a"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Polish paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_workbench_result(result)
      workbench = result.fetch("workbench")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = workbench["blocking_issues"] || result["blocking_issues"] || []
      panels = Array(workbench["panels"])
      controls = Array(workbench["controls"])
      paths = []
      %w[index_path manifest_path planned_index_path planned_manifest_path].each do |key|
        value = workbench[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      if workbench["paths"].is_a?(Hash)
        workbench["paths"].each do |key, value|
          paths << "#{key}=#{value}" unless value.to_s.empty?
        end
      end
      serve = workbench["serve"].is_a?(Hash) ? workbench["serve"] : {}
      [
        "Workbench status: #{workbench["status"] || "n/a"}",
        "Dry run: #{workbench.key?("dry_run") ? workbench["dry_run"] : "n/a"}",
        "Serve URL: #{serve["url"] || "n/a"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Workbench paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Panels: #{panels.empty? ? "none" : panels.join(", ")}",
        "Controls: #{controls.empty? ? "none" : controls.map { |control| control.is_a?(Hash) ? control["command"] || control["id"] : control }.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_component_map_result(result)
      map = result.fetch("component_map")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = map["blocking_issues"] || result["blocking_issues"] || []
      path = map["artifact_path"] || map["planned_artifact_path"] || result["artifact_path"]
      components = Array(map["components"])
      [
        "Component map: #{map["status"] || "n/a"}",
        "Dry run: #{map.key?("dry_run") ? map["dry_run"] : "n/a"}",
        "Artifact: #{path || "n/a"}",
        "Components: #{components.length}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_visual_edit_result(result)
      edit = result.fetch("visual_edit")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = edit["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[task_path record_path planned_task_path planned_record_path visual_edit_record_path planned_visual_edit_record_path].each do |key|
        value = edit[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Visual edit: #{edit["status"] || "n/a"}",
        "Target: #{edit["target"] || edit.dig("target_mapping", "data_aiweb_id") || "n/a"}",
        "Map source: #{edit["map_source"] || edit["from_map"] || "latest"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Visual edit paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_repair_result(result)
      loop = result.fetch("repair_loop")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = loop["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[repair_record_path snapshot_path fix_task_path planned_repair_record_path planned_snapshot_path planned_fix_task_path].each do |key|
        value = loop[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Repair loop: #{loop["status"] || "n/a"}",
        "QA source: #{loop["qa_source"] || loop["from_qa"] || "n/a"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Repair paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_runtime_plan_result(result)
      plan = result.fetch("runtime_plan")
      blockers = plan.fetch("blockers", [])
      lines = [
        "Runtime readiness: #{plan.fetch("readiness")}",
        "Scaffold: profile=#{plan.dig("scaffold", "profile") || "n/a"} framework=#{plan.dig("scaffold", "framework") || "n/a"} package_manager=#{plan.dig("scaffold", "package_manager") || "n/a"}",
        "Commands: dev=#{plan.dig("scaffold", "dev_command") || "n/a"} build=#{plan.dig("scaffold", "build_command") || "n/a"}",
        "Selected design: #{plan.dig("design", "selected_candidate") || "none"}",
        "Missing files: #{plan.fetch("missing_required_scaffold_files").empty? ? "none" : plan.fetch("missing_required_scaffold_files").join(", ")}",
        "Blockers: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ]
      lines.join("\n")
    end

    def human_agent_run_result(result)
      agent_run = result.fetch("agent_run")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = agent_run["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[run_dir stdout_path stderr_path metadata_path diff_path planned_run_dir planned_stdout_path planned_stderr_path planned_metadata_path planned_diff_path].each do |key|
        value = agent_run[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Agent run: #{agent_run["status"] || "n/a"}",
        "Task: #{agent_run["task"] || "n/a"}",
        "Agent: #{agent_run["agent"] || "n/a"}",
        "Dry run: #{agent_run.key?("dry_run") ? agent_run["dry_run"] : "n/a"}",
        "Approved: #{agent_run.key?("approved") ? agent_run["approved"] : "n/a"}",
        "Command: #{agent_run["command"] || "n/a"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Agent run paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_verify_loop_result(result)
      loop = result.fetch("verify_loop")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = loop["blocking_issues"] || result["blocking_issues"] || []
      steps = Array(loop["planned_steps"]).empty? ? Array(loop["cycles"]).flat_map { |cycle| Array(cycle["steps"]).map { |step| step["name"] } }.uniq : Array(loop["planned_steps"]).flat_map { |cycle| cycle["steps"] }.uniq
      [
        "Verify loop: #{loop["status"] || "n/a"}",
        "Max cycles: #{loop["max_cycles"] || "n/a"}",
        "Cycles run: #{loop["cycle_count"] || 0}",
        "Dry run: #{loop.key?("dry_run") ? loop["dry_run"] : "n/a"}",
        "Approved: #{loop.key?("approved") ? loop["approved"] : "n/a"}",
        "Metadata: #{loop["metadata_path"] || "n/a"}",
        "Run dir: #{loop["run_dir"] || "n/a"}",
        "Steps: #{steps.empty? ? "none" : steps.join(", ")}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_registry_result(result)
      registry_payload = result.fetch("registry")
      items = registry_payload.fetch("items")
      lines = ["#{registry_payload.fetch("label")} (#{registry_payload.fetch("count")})"]
      unless registry_payload.fetch("exists")
        lines << "Directory not found: #{registry_payload.fetch("directory")}/"
      end
      if items.empty?
        lines << "No #{registry_payload.fetch("singular")} entries found."
      else
        items.each do |item|
          description = item["description"].to_s.empty? ? "" : " — #{item["description"]}"
          lines << "- #{item["id"]}: #{item["title"]} (#{item["path"]})#{description}"
        end
      end
      validation_errors = result["validation_errors"] || []
      warnings = result["warnings"] || []
      lines << "Validation errors: #{validation_errors.join("; ")}" unless validation_errors.empty?
      lines << "Warnings: #{warnings.join("; ")}" unless warnings.empty?
      lines.join("\n")
    end

    def setup_exit_code(result)
      status = result.dig("setup", "status").to_s
      return EXIT_SUCCESS if %w[planned dry_run passed completed].include?(status)
      return EXIT_PHASE_BLOCKED if status == "blocked" && ((result.dig("setup", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ").match?(/phase|runtime-plan|readiness|initialized/i)
      return EXIT_UNSAFE_EXTERNAL_ACTION if status == "blocked" && ((result.dig("setup", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ").match?(/approved|approval|unsafe/i)

      EXIT_VALIDATION_FAILED
    end

    def agent_run_exit_code(result)
      status = result.dig("agent_run", "status").to_s
      return EXIT_SUCCESS if %w[planned dry_run passed completed].include?(status)
      return EXIT_ADAPTER_UNAVAILABLE if status == "blocked" && (result["action_taken"].to_s =~ /unavailable/)
      if status == "blocked"
        issues = ((result.dig("agent_run", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ")
        return EXIT_UNSAFE_EXTERNAL_ACTION if issues.match?(/\.env|no implementation task|task packet|safe source target|source targets?|source target|available|missing-target|missing target|required|approved|approval|unsafe|guardrail/i)
        return EXIT_PHASE_BLOCKED if issues.match?(/phase/i)
      end
      return EXIT_VALIDATION_FAILED if %w[failed no_changes].include?(status)

      EXIT_VALIDATION_FAILED
    end

    def build_exit_code(result)
      result.dig("build", "status") == "passed" || result.dig("build", "status") == "dry_run" ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED
    end

    def preview_exit_code(result)
      %w[dry_run running already_running stopped not_running].include?(result.dig("preview", "status")) ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED
    end

    def qa_playwright_exit_code(result)
      %w[dry_run passed].include?(result.dig("playwright_qa", "status")) ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED
    end

    def qa_screenshot_exit_code(result)
      status = result.dig("screenshot_qa", "status").to_s
      return EXIT_SUCCESS if %w[dry_run passed].include?(status)
      return EXIT_ADAPTER_UNAVAILABLE if status == "blocked" && (result["action_taken"].to_s =~ /unavailable/)

      EXIT_VALIDATION_FAILED
    end

    def qa_a11y_exit_code(result)
      %w[dry_run passed].include?(result.dig("a11y_qa", "status")) ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED
    end

    def qa_lighthouse_exit_code(result)
      %w[dry_run passed].include?(result.dig("lighthouse_qa", "status")) ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED
    end

    def visual_critique_exit_code(result)
      critique = result["visual_critique"] || {}
      status = critique["status"].to_s
      return EXIT_SUCCESS if %w[dry_run planned].include?(status)
      return EXIT_ADAPTER_UNAVAILABLE if status == "blocked" && (result["action_taken"].to_s =~ /unavailable/)
      return EXIT_VALIDATION_FAILED if status == "blocked"

      critique["approval"].to_s == "pass" ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED
    end

    def repair_exit_code(result)
      status = result.dig("repair_loop", "status")
      return EXIT_SUCCESS if %w[planned dry_run created reused].include?(status)
      return EXIT_VALIDATION_FAILED unless status == "blocked"

      issues = ((result.dig("repair_loop", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ")
      return EXIT_BUDGET_BLOCKED if issues.match?(/budget|cycle|cap|max-cycles|max cycles/i)
      return EXIT_PHASE_BLOCKED if issues.match?(/phase/i)

      EXIT_VALIDATION_FAILED
    end

    def visual_polish_exit_code(result)
      status = result.dig("visual_polish", "status")
      return EXIT_SUCCESS if %w[planned dry_run created reused].include?(status)
      return EXIT_ADAPTER_UNAVAILABLE if status == "blocked" && (result["action_taken"].to_s =~ /unavailable/)
      return EXIT_VALIDATION_FAILED unless status == "blocked"

      issues = ((result.dig("visual_polish", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ")
      return EXIT_BUDGET_BLOCKED if issues.match?(/budget|cycle|cap|max-cycles|max cycles/i)
      return EXIT_PHASE_BLOCKED if issues.match?(/phase/i)

      EXIT_VALIDATION_FAILED
    end

    def verify_loop_exit_code(result)
      status = result.dig("verify_loop", "status").to_s
      return EXIT_SUCCESS if %w[dry_run planned passed cancelled].include?(status)
      return EXIT_BUDGET_BLOCKED if status == "max_cycles"
      if status == "blocked"
        issues = ((result.dig("verify_loop", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ")
        return EXIT_UNSAFE_EXTERNAL_ACTION if issues.match?(/approved|approval|unsafe|\.env|deploy|provider/i)
        return EXIT_PHASE_BLOCKED if issues.match?(/phase|runtime-plan|scaffold|initialized/i)
      end
      return EXIT_VALIDATION_FAILED if status == "agent_run_failed"

      EXIT_VALIDATION_FAILED
    end

    def run_lifecycle_exit_code(result)
      status = result.dig("run_lifecycle", "status").to_s
      return EXIT_SUCCESS if %w[idle running cancel_planned cancel_requested resume_planned].include?(status)
      return EXIT_VALIDATION_FAILED if status == "blocked"

      EXIT_SUCCESS
    end

    def component_map_exit_code(result)
      status = result.dig("component_map", "status").to_s
      return EXIT_ADAPTER_UNAVAILABLE if status == "blocked" && (result["action_taken"].to_s =~ /unavailable/)
      return EXIT_SUCCESS if %w[planned discovered created ready].include?(status)
      return EXIT_PHASE_BLOCKED if status == "blocked" && ((result.dig("component_map", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ").match?(/phase/i)

      EXIT_VALIDATION_FAILED
    end

    def visual_edit_exit_code(result)
      status = result.dig("visual_edit", "status").to_s
      return EXIT_ADAPTER_UNAVAILABLE if status == "blocked" && (result["action_taken"].to_s =~ /unavailable/)
      return EXIT_SUCCESS if %w[planned created].include?(status)
      return EXIT_PHASE_BLOCKED if status == "blocked" && ((result.dig("visual_edit", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ").match?(/phase/i)

      EXIT_VALIDATION_FAILED
    end

    def github_sync_exit_code(result)
      result.dig("github_sync", "status") == "planned" ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED
    end

    def deploy_plan_exit_code(result)
      result.dig("deploy_plan", "status") == "planned" ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED
    end

    def deploy_exit_code(result)
      status = result.dig("deploy", "status").to_s
      return EXIT_SUCCESS if %w[planned passed].include?(status)
      issues = ((result.dig("deploy", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ")
      return EXIT_UNSAFE_EXTERNAL_ACTION if issues.match?(/unsafe.*deploy.*blocked|approved|approval|provider CLI|verify-loop|deploy output|missing/i)

      EXIT_VALIDATION_FAILED
    end

    def supabase_secret_qa_exit_code(result)
      status = result.dig("supabase_secret_qa", "status").to_s
      return EXIT_ADAPTER_UNAVAILABLE if status == "blocked" && (result["action_taken"].to_s =~ /unavailable/)
      return EXIT_SUCCESS if %w[planned dry_run passed].include?(status)
      return EXIT_PHASE_BLOCKED if status == "blocked" && ((result.dig("supabase_secret_qa", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ").match?(/phase/i)

      EXIT_VALIDATION_FAILED
    end

    def supabase_local_verify_exit_code(result)
      status = result.dig("supabase_local_verify", "status").to_s
      return EXIT_ADAPTER_UNAVAILABLE if status == "blocked" && (result["action_taken"].to_s =~ /unavailable/)
      return EXIT_SUCCESS if %w[planned dry_run passed].include?(status)
      return EXIT_PHASE_BLOCKED if status == "blocked" && ((result.dig("supabase_local_verify", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ").match?(/phase/i)

      EXIT_VALIDATION_FAILED
    end

    def workbench_exit_code(result)
      status = result.dig("workbench", "status").to_s
      return EXIT_ADAPTER_UNAVAILABLE if status == "blocked" && (result["action_taken"].to_s =~ /unavailable/)
      return EXIT_SUCCESS if %w[planned exported ready running already_running].include?(status)
      return EXIT_PHASE_BLOCKED if status == "blocked" && ((result.dig("workbench", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ").match?(/phase/i)
      return EXIT_UNSAFE_EXTERNAL_ACTION if status == "blocked" && ((result.dig("workbench", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ").match?(/approved|unsafe|host|localhost|127\.0\.0\.1/i)

      EXIT_VALIDATION_FAILED
    end

    def exit_code_for(command, result)
      if result["validation_errors"] && !result["validation_errors"].empty?
        return EXIT_UNSAFE_EXTERNAL_ACTION if command == "design-systems"

        return EXIT_VALIDATION_FAILED
      end
      return result.dig("runtime_plan", "readiness") == "ready" ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED if RUNTIME_PLAN_COMMANDS.include?(command)
      return EXIT_SUCCESS if REGISTRY_COMMANDS.include?(command) || command == "intent"
      return run_lifecycle_exit_code(result) if %w[run-status run-cancel run-resume].include?(command)
      return EXIT_SUCCESS if %w[run-timeline timeline observability-summary summary].include?(command)
      return setup_exit_code(result) if command == "setup"
      return agent_run_exit_code(result) if command == "agent-run"
      return build_exit_code(result) if command == "build"
      return preview_exit_code(result) if command == "preview"
      return qa_playwright_exit_code(result) if %w[qa-playwright browser-qa].include?(command)
      return qa_screenshot_exit_code(result) if %w[qa-screenshot screenshot-qa].include?(command)
      return qa_a11y_exit_code(result) if %w[qa-a11y a11y-qa].include?(command)
      return qa_lighthouse_exit_code(result) if %w[qa-lighthouse lighthouse-qa].include?(command)
      return visual_critique_exit_code(result) if command == "visual-critique"
      return repair_exit_code(result) if command == "repair"
      return visual_polish_exit_code(result) if command == "visual-polish"
      return verify_loop_exit_code(result) if command == "verify-loop"
      return workbench_exit_code(result) if command == "workbench"
      return component_map_exit_code(result) if command == "component-map"
      return visual_edit_exit_code(result) if command == "visual-edit"
      return github_sync_exit_code(result) if command == "github-sync"
      return deploy_plan_exit_code(result) if command == "deploy-plan"
      return deploy_exit_code(result) if command == "deploy"
      return supabase_secret_qa_exit_code(result) if command == "supabase-secret-qa"
      return supabase_local_verify_exit_code(result) if command == "supabase-local-verify"
      return EXIT_SUCCESS if %w[help version status start init interview run run-status run-timeline timeline observability-summary summary run-cancel run-resume agent-run verify-loop design-brief design-research design-system design-prompt design select-design scaffold ingest-reference ingest-design next-task qa-checklist qa-report rollback resolve-blocker snapshot visual-critique visual-polish component-map visual-edit].include?(command)
      if command == "advance" && result["action_taken"] == "advance blocked"
        issue = result["blocking_issues"].join(" ")
        return EXIT_BUDGET_BLOCKED if issue =~ /budget|candidate cap|design generation cap/i
        return EXIT_PHASE_BLOCKED
      end
      EXIT_SUCCESS
    end
  end
end
