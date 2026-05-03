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

    MUTATION_COMMANDS = %w[start init interview run ingest-design next-task qa-checklist qa-report repair advance rollback resolve-blocker snapshot design-brief design-system design-prompt design select-design scaffold build preview qa-playwright browser-qa qa-a11y a11y-qa qa-lighthouse lighthouse-qa visual-critique visual-polish workbench].freeze
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

          @root = File.expand_path(value)
        when /\A--path=(.+)\z/
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
      when "design-brief"
        opts = parse_options do |o, options|
          o.on("--force") { options[:force] = true }
        end
        project.design_brief(dry_run: @dry_run, force: opts[:force])
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
          o.on("--task-id ID") { |v| options[:task_id] = v }
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("visual-critique does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        unless project.respond_to?(:visual_critique)
          return visual_critique_adapter_unavailable_payload(opts)
        end

        project.visual_critique(screenshot: opts[:screenshot], metadata: opts[:metadata], task_id: opts[:task_id], force: opts[:force], dry_run: @dry_run)
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
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("workbench does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        unless project.respond_to?(:workbench)
          return workbench_adapter_unavailable_payload(opts)
        end

        project.workbench(export: opts[:export], force: opts[:force], dry_run: @dry_run)
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
        "aiweb visual-polish"
      ].map do |command|
        {
          "command" => command,
          "mode" => "descriptor",
          "writes_state_directly" => false
        }
      end
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
          design-brief [--force]
          design-system resolve [--force]
          design-prompt [--force]
          design --candidates 3 [--force]
          select-design candidate-01|candidate-02|candidate-03
          scaffold --profile D [--force]
          runtime-plan (alias: scaffold-status)
          build
          ingest-design [--id ID] [--title TITLE] [--source SOURCE] [--notes NOTES] [--selected] [--force]
          next-task [--type TYPE] [--force]
          qa-checklist [--force]
          qa-report [--from PATH] [--status passed|failed|blocked] [--duration-minutes N] [--timed-out] [--force]
          repair [--from-qa PATH|latest] [--max-cycles N] [--force]
          qa-playwright [--url URL] [--task-id ID] [--force]
          qa-a11y [--url URL] [--task-id ID] [--force]
          qa-lighthouse [--url URL] [--task-id ID] [--force]
          visual-critique [--screenshot PATH] [--metadata PATH] [--task-id ID] [--force]
          visual-polish --repair [--from-critique PATH|latest] [--max-cycles N] [--force]
          workbench [--export] [--force]
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
          design-prompt: phase-3 or phase-3.5
          design: creates deterministic HTML design candidates without app scaffold
          select-design: records selected HTML candidate without overwriting DESIGN.md
          scaffold: creates Profile D Astro-style static app skeleton without installing packages
          runtime-plan/scaffold-status: read-only runtime readiness metadata; does not install or launch Node
          build: runs the scaffolded Astro build only after runtime-plan is ready and records .ai-web/runs logs
          preview: starts/stops the local scaffold dev server after runtime-plan is ready; --dry-run does not write files or launch Node
          qa-playwright: runs safe local Playwright QA browser checks against localhost/127.0.0.1 preview; --dry-run does not write files or launch Node
          qa-a11y: runs safe local axe accessibility QA against localhost/127.0.0.1 preview; --dry-run does not write files or launch Node
          qa-lighthouse: runs safe local Lighthouse QA against localhost/127.0.0.1 preview; --dry-run does not write files or launch Node
          visual-critique: records safe local visual critique from explicit screenshot/metadata evidence only; --dry-run plans .ai-web/visual artifacts without writes, browser launch, installs, repair, deploy, network, or .env access
          workbench: plans or exports a static local UI manifest under .ai-web/workbench using declarative CLI controls only; requires initialized .ai-web/state.yaml, --dry-run writes nothing, export writes only workbench artifacts, executes no controls, and never mutates state.yaml
          ingest-design: phase-3.5
          next-task: phase-6 through phase-11
          qa-checklist: phase-7 through phase-11
          qa-report: phase-7 through phase-11
          repair: phase-7 through phase-11; records a bounded local repair-loop task from failed/blocked QA without running build, QA, preview, deploy, package install, or source auto-patches
          visual-critique: phase-7 through phase-11; records deterministic local visual critique evidence from explicit input paths only
          visual-polish --repair: records safe local visual polish repair loop from failed/repair/redesign critique evidence in phase-7 through phase-11 without source edits, build, QA, preview, browser capture, deploy, package install, network, or AI calls
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
      return human_repair_result(result) if result["repair_loop"]
      return human_visual_critique_result(result) if result["visual_critique"]
      return human_visual_polish_result(result) if result["visual_polish"]
      return human_workbench_result(result) if result["workbench"]

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
      [
        "Workbench status: #{workbench["status"] || "n/a"}",
        "Dry run: #{workbench.key?("dry_run") ? workbench["dry_run"] : "n/a"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Workbench paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Panels: #{panels.empty? ? "none" : panels.join(", ")}",
        "Controls: #{controls.empty? ? "none" : controls.map { |control| control.is_a?(Hash) ? control["command"] || control["id"] : control }.join(", ")}",
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

    def build_exit_code(result)
      result.dig("build", "status") == "passed" || result.dig("build", "status") == "dry_run" ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED
    end

    def preview_exit_code(result)
      %w[dry_run running already_running stopped not_running].include?(result.dig("preview", "status")) ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED
    end

    def qa_playwright_exit_code(result)
      %w[dry_run passed].include?(result.dig("playwright_qa", "status")) ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED
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

    def workbench_exit_code(result)
      status = result.dig("workbench", "status").to_s
      return EXIT_ADAPTER_UNAVAILABLE if status == "blocked" && (result["action_taken"].to_s =~ /unavailable/)
      return EXIT_SUCCESS if %w[planned exported ready].include?(status)
      return EXIT_PHASE_BLOCKED if status == "blocked" && ((result.dig("workbench", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ").match?(/phase/i)

      EXIT_VALIDATION_FAILED
    end

    def exit_code_for(command, result)
      return EXIT_VALIDATION_FAILED if result["validation_errors"] && !result["validation_errors"].empty?
      return result.dig("runtime_plan", "readiness") == "ready" ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED if RUNTIME_PLAN_COMMANDS.include?(command)
      return EXIT_SUCCESS if REGISTRY_COMMANDS.include?(command) || command == "intent"
      return build_exit_code(result) if command == "build"
      return preview_exit_code(result) if command == "preview"
      return qa_playwright_exit_code(result) if %w[qa-playwright browser-qa].include?(command)
      return qa_a11y_exit_code(result) if %w[qa-a11y a11y-qa].include?(command)
      return qa_lighthouse_exit_code(result) if %w[qa-lighthouse lighthouse-qa].include?(command)
      return visual_critique_exit_code(result) if command == "visual-critique"
      return repair_exit_code(result) if command == "repair"
      return visual_polish_exit_code(result) if command == "visual-polish"
      return workbench_exit_code(result) if command == "workbench"
      return EXIT_SUCCESS if %w[help version status start init interview run design-brief design-system design-prompt design select-design scaffold ingest-design next-task qa-checklist qa-report rollback resolve-blocker snapshot visual-critique visual-polish].include?(command)
      if command == "advance" && result["action_taken"] == "advance blocked"
        issue = result["blocking_issues"].join(" ")
        return EXIT_BUDGET_BLOCKED if issue =~ /budget|candidate cap|design generation cap/i
        return EXIT_PHASE_BLOCKED
      end
      EXIT_SUCCESS
    end
  end
end
