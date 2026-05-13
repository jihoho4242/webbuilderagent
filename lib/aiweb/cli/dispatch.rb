# frozen_string_literal: true

module Aiweb
  class CLI
    module Dispatch
      private

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
      when "engine-run"
        dispatch_engine_run
      when "agent-run"
        dispatch_agent_run
      when "verify-loop"
        opts = parse_options do |o, options|
          o.on("--max-cycles N") { |v| options[:max_cycles] = parse_positive_integer(v, "--max-cycles") }
          o.on("--agent AGENT") { |v| options[:agent] = v }
          o.on("--sandbox SANDBOX") { |v| options[:sandbox] = v }
          o.on("--approved") { options[:approved] = true }
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("verify-loop does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.verify_loop(max_cycles: opts[:max_cycles] || 3, agent: opts[:agent], sandbox: opts[:sandbox], approved: !!opts[:approved], force: opts[:force], dry_run: @dry_run)
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
        project.supabase_secret_qa(dry_run: @dry_run, force: opts[:force])
      when "supabase-local-verify"
        opts = parse_options do |o, options|
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("supabase-local-verify does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
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
          o.on("--approved") { options[:approved] = true }
          o.on("--host HOST") { |v| options[:host] = v }
          o.on("--port N") { |v| options[:port] = parse_positive_integer(v, "--port") }
          o.on("--force") { options[:force] = true }
        end
        unless @argv.empty?
          raise UserError.new("workbench does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
        end
        project.workbench(export: opts[:export], serve: opts[:serve], approved: !!opts[:approved], host: opts[:host] || "127.0.0.1", port: opts[:port], force: opts[:force], dry_run: @dry_run)
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
        o.on("--sandbox SANDBOX") { |v| options[:sandbox] = v }
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

      call_project_adapter(:agent_run, { task: task, agent: agent, sandbox: sandbox.empty? ? nil : sandbox, approved: approved, dry_run: @dry_run }).tap do |result|
        normalize_agent_run_payload!(result, task: task, agent: agent, approved: approved, dry_run: @dry_run)
      end
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
      raise UserError.new("engine-run --sandbox is only supported with --agent openmanus", EXIT_VALIDATION_FAILED) if !sandbox.empty? && agent != "openmanus"
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

    end
  end
end
