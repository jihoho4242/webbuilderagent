# frozen_string_literal: true

require "ripper"

module Aiweb
  module ProjectSideEffectBroker
    SIDE_EFFECT_SURFACE_PATTERNS = [
      /\bOpen3\.(?:capture3|popen3|capture2e|pipeline)/,
      /\bNet::HTTP(?:\.start|\.new|\.get|\.post)/,
      /\bProcess\.spawn\b/,
      /\bIO\.popen\b/,
      /\bKernel\.(?:system|spawn|exec)\b/,
      /(?<![.\w-])system\(/,
      /(?:\A\s*|=\s*)system\s+/,
      /(?<![.\w-])spawn\(/,
      /(?:\A\s*|=\s*)spawn\s+/,
      /(?<![.\w-])exec\(/,
      /(?:\A\s*|=\s*)exec\s+/
    ].freeze
    SIDE_EFFECT_SURFACE_SCANNED_GLOBS = %w[
      bin/**/*
      lib/**/*
      scripts/**/*
      tasks/**/*
      Rakefile
      *.rake
      *.gemspec
      Gemfile
      aiweb
      웹빌더
    ].freeze

    private

    def side_effect_broker_plan(broker:, scope:, target:, command:, broker_path:, dry_run:, approved:, blocked:, blockers:, risk_class:, requires_approval: true, policy_extra: {})
      decision =
        if dry_run
          "plan-only"
        elsif blocked
          "deny"
        elsif approved
          "allow"
        else
          "deny"
        end
      {
        "schema_version" => 1,
        "broker" => broker,
        "scope" => scope,
        "status" => dry_run ? "planned" : (blocked ? "blocked" : "ready"),
        "events_recorded" => false,
        "events_path" => relative(broker_path),
        "event_count" => 0,
        "target" => target,
        "tool" => Array(command).first.to_s,
        "command" => redact_side_effect_command(command),
        "risk_class" => risk_class,
        "requires_approval" => requires_approval,
        "approved" => approved,
        "policy" => {
          "decision" => decision,
          "blocking_issues" => blocked ? blockers.uniq : []
        }.merge(policy_extra)
      }
    end

    def side_effect_broker_context(broker:, scope:, target:, command:, risk_class:, approved:, requires_approval: true, extra: {})
      {
        "broker" => broker,
        "scope" => scope,
        "target" => target,
        "tool" => Array(command).first.to_s,
        "command" => redact_side_effect_command(command),
        "risk_class" => risk_class,
        "requires_approval" => requires_approval,
        "approved" => approved
      }.merge(extra)
    end

    def append_side_effect_broker_event(path, events, event, payload)
      raise UserError.new("side-effect broker path is outside aiweb run evidence", 5) unless side_effect_broker_path_allowed?(path)

      broker_event = {
        "schema_version" => 1,
        "event" => event,
        "created_at" => now
      }.merge(payload)
      events << broker_event
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "a") do |file|
        file.write(JSON.generate(broker_event))
        file.write("\n")
      end
      broker_event
    end

    def redact_side_effect_command(command)
      previous = nil
      Array(command).map do |part|
        value = part.to_s
        redacted = side_effect_secret_arg?(value, previous) ? "[REDACTED]" : value
        previous = value
        redacted
      end
    end

    def redact_side_effect_process_output(text)
      in_private_key_block = false
      line_redacted = text.to_s.lines.map do |line|
        if in_private_key_block
          in_private_key_block = false if side_effect_private_key_end_line?(line)
          side_effect_redacted_line(line)
        elsif side_effect_secret_assignment_line?(line) || side_effect_private_key_begin_line?(line)
          in_private_key_block = true if side_effect_private_key_begin_line?(line) && !side_effect_private_key_end_line?(line)
          side_effect_redacted_line(line)
        else
          line
        end
      end.join
      redacted = agent_run_redact_process_output(line_redacted)
      redacted = redacted.gsub(/(Authorization:\s*Bearer\s+)[^\s]+/i, "\\1[redacted]")
      redacted = redacted.gsub(/\b([A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|PRIVATE[_-]?KEY|API[_-]?KEY|CREDENTIAL|AUTH)[A-Z0-9_]*\s*:\s*)[^\s]+/i, "\\1[redacted]")
      redacted = redacted.gsub(/\b((?:access[_-]?token|api[_-]?key|key|password|secret|token|credential|authorization)\s*:\s*)[^\s]+/i, "\\1[redacted]")
      redacted = redacted.gsub(/([?&](?:access_token|api[_-]?key|key|password|secret|token|signature)=)[^&\s]+/i, "\\1[redacted]")
      redacted.gsub(%r{(?<![\w.-])\.env(?:\.[A-Za-z0-9_-]+)?(?=$|[/:;,\s'"`)\]])}, "[excluded unsafe environment-file reference]")
    end

    def side_effect_secret_arg?(value, previous)
      return true if value.match?(/\A--?[^=\s]*(?:token|secret|client[-_]?secret|password|passwd|api[-_]?key|auth|authorization|credential|private[-_]?key)[^=\s]*=/i)
      return true if previous.to_s.match?(/\A--?[^=\s]*(?:token|secret|client[-_]?secret|password|passwd|api[-_]?key|auth|authorization|credential|private[-_]?key)[^=\s]*\z/i)

      false
    end

    def side_effect_secret_assignment_line?(line)
      line.to_s.match?(/\b(?:KEY|[A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|PRIVATE[_-]?KEY|API[_-]?KEY|CREDENTIAL|AUTH)[A-Z0-9_]*|access[_-]?token|api[_-]?key|password|secret|token|credential|authorization)\s*[:=]/i) ||
        line.to_s.match?(/Authorization:\s*Bearer\s+/i)
    end

    def side_effect_private_key_begin_line?(line)
      line.to_s.match?(/-----BEGIN [A-Z ]*PRIVATE KEY-----/i)
    end

    def side_effect_private_key_end_line?(line)
      line.to_s.match?(/-----END [A-Z ]*PRIVATE KEY-----/i)
    end

    def side_effect_redacted_line(line)
      line.to_s.end_with?("\n") ? "[redacted]\n" : "[redacted]"
    end

    def side_effect_broker_path_allowed?(path)
      full = File.expand_path(path.to_s)
      runs_dir = File.expand_path(File.join(aiweb_dir, "runs"))
      full.start_with?(runs_dir + File::SEPARATOR) && File.basename(full) == "side-effect-broker.jsonl"
    end

    def side_effect_surface_audit
      roots = side_effect_surface_roots
      entries = roots.flat_map do |surface_root|
        side_effect_surface_candidate_files(surface_root.fetch("path"))
          .flat_map { |path| side_effect_surface_entries_for(path, base_root: surface_root.fetch("path"), source: surface_root.fetch("source")) }
      end
      unclassified = entries.select { |entry| entry["coverage_status"] == "unclassified" }
      {
        "schema_version" => 1,
        "scanner" => "aiweb.side_effect_surface_audit.v1",
        "scope" => "runtime_and_project_task_static_process_and_network_surface",
        "roots" => roots.map { |surface_root| surface_root.merge("path" => side_effect_surface_display_path(surface_root.fetch("path"))) },
        "scanned_globs" => SIDE_EFFECT_SURFACE_SCANNED_GLOBS,
        "scanner_limitations" => [
          "static text scanner over runtime/project bin, lib, scripts, tasks, root Ruby task files, and aiweb launcher wrappers; generated files outside those globs and non-Ruby package scripts are not covered",
          "classification evidence prevents unqualified universal-broker claims but is not itself a runtime enforcement broker",
          "MCP/connectors beyond approved Lazyweb health/search, future adapters, and elevated runners still require explicit broker-mediated integrations"
        ],
        "entry_count" => entries.length,
        "unclassified_count" => unclassified.length,
        "coverage_status" => unclassified.empty? ? "classified" : "unclassified",
        "policy" => {
          "new_direct_side_effects_must_be_classified" => true,
          "brokered_statuses" => %w[brokered documented_exception],
          "unclassified_blocks_claiming_universal_broker" => true
        },
        "entries" => entries
      }
    end

    def side_effect_surface_candidate_files(base_root)
      SIDE_EFFECT_SURFACE_SCANNED_GLOBS.flat_map { |glob| Dir.glob(File.join(base_root, glob)) }
                                       .select { |path| File.file?(path) }
                                       .uniq
                                       .sort
    end

    def side_effect_surface_roots
      roots = [
        { "source" => "aiweb_runtime", "path" => side_effect_runtime_root },
        { "source" => "project_root", "path" => root }
      ]
      seen = {}
      roots.filter_map do |entry|
        path = File.expand_path(entry.fetch("path"))
        next if seen[path]

        seen[path] = true
        entry.merge("path" => path)
      end
    end

    def side_effect_runtime_root
      File.expand_path("../../..", __dir__)
    end

    def side_effect_surface_display_path(path)
      full = File.expand_path(path)
      full == File.expand_path(root) ? "." : full.tr("\\", "/")
    end

    def side_effect_surface_entries_for(path, base_root:, source:)
      rel = side_effect_surface_relative(path, base_root)
      return [] if rel.end_with?("lib/aiweb/project/side_effect_broker.rb")

      lines = File.readlines(path, chomp: true)
      regex_entries = lines.each_with_index.filter_map do |line, index|
        next if side_effect_surface_comment_line?(line)

        matched = SIDE_EFFECT_SURFACE_PATTERNS.find { |pattern| line.match?(pattern) }
        next unless matched

        side_effect_surface_entry(rel, source, index + 1, matched.source, line, lines, index)
      end
      (regex_entries + side_effect_surface_backtick_entries_for(rel, source, lines) + side_effect_surface_command_form_entries_for(rel, source, lines))
        .uniq { |entry| [entry["path"], entry["line"], entry["snippet"]] }
    rescue SystemCallError, Encoding::InvalidByteSequenceError
      []
    end

    def side_effect_surface_backtick_entries_for(path, source, lines)
      Ripper.lex(lines.join("\n")).filter_map do |token|
        position, type, value, = token
        next unless type == :on_backtick

        line_no = position.fetch(0)
        line = lines.fetch(line_no - 1, "")
        side_effect_surface_entry(path, source, line_no, value.to_s.start_with?("%x") ? "ruby_percent_x_command" : "ruby_backtick_command", line, lines, line_no - 1)
      end
    rescue StandardError
      []
    end

    def side_effect_surface_command_form_entries_for(path, source, lines)
      tokens = Ripper.lex(lines.join("\n"))
      tokens.each_with_index.filter_map do |token, index|
        position, type, value, = token
        next unless type == :on_ident && %w[system spawn exec].include?(value.to_s)
        next if side_effect_surface_qualified_or_defined_command?(tokens, index)
        next unless side_effect_surface_command_call?(tokens, index)

        line_no = position.fetch(0)
        line = lines.fetch(line_no - 1, "")
        side_effect_surface_entry(path, source, line_no, "ruby_command_form_#{value}", line, lines, line_no - 1)
      end
    rescue StandardError
      []
    end

    def side_effect_surface_qualified_or_defined_command?(tokens, index)
      previous = side_effect_surface_previous_significant_token(tokens, index)
      return true if previous && previous[1] == :on_period
      return true if previous && previous[1] == :on_op && %w[. &. ::].include?(previous[2].to_s)
      return true if previous && previous[1] == :on_kw && previous[2].to_s == "def"

      false
    end

    def side_effect_surface_command_call?(tokens, index)
      following = side_effect_surface_next_significant_token(tokens, index)
      return false unless following
      return false if following[1] == :on_op && %w[= += -= *= /= %= **= &= |= ^= <<= >>= &&= ||=].include?(following[2].to_s)

      command_arg_types = %i[on_lparen on_tstring_beg on_backtick on_ident on_const on_int on_float on_ivar on_cvar on_gvar on_kw on_lbracket on_lbrace]
      command_arg_types.include?(following[1])
    end

    def side_effect_surface_previous_significant_token(tokens, index)
      cursor = index - 1
      while cursor >= 0
        token = tokens[cursor]
        return token unless side_effect_surface_ignorable_token?(token)

        cursor -= 1
      end
      nil
    end

    def side_effect_surface_next_significant_token(tokens, index)
      cursor = index + 1
      while cursor < tokens.length
        token = tokens[cursor]
        return token unless side_effect_surface_ignorable_token?(token)

        cursor += 1
      end
      nil
    end

    def side_effect_surface_ignorable_token?(token)
      %i[on_sp on_ignored_nl on_nl on_comment].include?(token[1])
    end

    def side_effect_surface_comment_line?(line)
      line.to_s.strip.start_with?("#")
    end

    def side_effect_surface_entry(path, source, line_no, pattern, line, lines, index)
      classification = side_effect_surface_classification(path, line, lines, index)
      {
        "path" => path,
        "source" => source,
        "line" => line_no,
        "pattern" => pattern,
        "snippet" => redact_side_effect_process_output(line.to_s.strip)[0, 240],
        "classification" => classification.fetch("classification"),
        "coverage_status" => classification.fetch("coverage_status"),
        "broker" => classification["broker"],
        "rationale" => classification.fetch("rationale")
      }.compact
    end

    def side_effect_surface_relative(path, base_root)
      base = File.expand_path(base_root.to_s)
      full = File.expand_path(path.to_s)
      rel = full.sub(/^#{Regexp.escape(base)}[\/\\]?/, "")
      rel.tr("\\", "/")
    end

    def side_effect_surface_classification(path, line, lines, index)
      context = lines[[index - 8, 0].max..[index + 8, lines.length - 1].min].join("\n")
      if path == "bin/check" || path == "bin/engine-runtime-matrix-check"
        return side_effect_classification("local_verification_harness_exception", "documented_exception", nil, "bin/* verification harnesses run local checks only and are not production agent side-effect paths")
      end
      if %w[aiweb 웹빌더].include?(path) && line.match?(/\A\s*exec\s+/) && side_effect_surface_safe_launcher_exec?(path, line)
        return side_effect_classification("local_cli_launcher_wrapper", "documented_exception", nil, "root launcher delegates to the repo-local aiweb executable")
      end
      return side_effect_classification("brokered_backend_cli_bridge", "brokered", "aiweb.backend.side_effect_broker", "backend bridge writes broker events before Open3.popen3") if path.end_with?("lib/aiweb/daemon/cli_bridge.rb") && line.include?("Open3.popen3")
      if path.end_with?("lib/aiweb/lazyweb_client.rb") && line.match?(/Net::HTTP/)
        return side_effect_classification("brokered_lazyweb_http", "brokered", "aiweb.lazyweb.side_effect_broker", "LazywebClient emits broker audit events around Net::HTTP")
      end
      if path.end_with?("lib/aiweb/project.rb") && line.include?("Open3.capture3") && context.include?("append_side_effect_broker_event")
        return side_effect_classification("brokered_deploy_provider_cli", "brokered", "aiweb.deploy.side_effect_broker", "deploy provider CLI execution is gated by approval/provenance checks and emits side-effect broker events")
      end
      if path.end_with?("lib/aiweb/project.rb") && line.match?(/git.*status/)
        return side_effect_classification("local_read_only_git_provenance", "documented_exception", nil, "git status subprocess is local read-only deploy provenance collection")
      end
      if path.end_with?("lib/aiweb/project.rb") && line.include?("Open3.capture3")
        return side_effect_classification("local_tool_version_probe", "documented_exception", nil, "tool version subprocesses are short local readiness probes with a timeout and clean environment")
      end
      if path.end_with?("lib/aiweb/project/agent_run/openmanus.rb") && line.include?("image\", \"inspect")
        return side_effect_classification("openmanus_sandbox_image_preflight", "documented_exception", nil, "Docker/Podman image inspect is a local preflight that only checks sandbox image availability")
      end
      if path.end_with?("lib/aiweb/project/agent_run/openmanus.rb") && line.include?("Open3.popen3")
        return side_effect_classification("brokered_openmanus_sandbox_subprocess", "brokered", "aiweb.openmanus.tool_broker", "OpenManus runs in an aiweb-managed sandbox with clean environment, network disabled, PATH-prepended tool broker, and copied-back scoped outputs")
      end
      if path.end_with?("lib/aiweb/project/runtime_commands.rb") && line.include?("Open3.capture3") && context.include?("append_side_effect_broker_event")
        return side_effect_classification("brokered_setup_supply_chain_command", "brokered", "aiweb.setup.side_effect_broker", "setup package-manager/SBOM/audit subprocess is surrounded by broker events")
      end
      if path.end_with?("lib/aiweb/project/runtime_commands.rb") && line.include?("Process.spawn")
        return side_effect_classification("local_preview_server_process", "documented_exception", nil, "preview server subprocess is local-only, logged under .ai-web/runs, and gated by existing dependency checks")
      end
      if path.end_with?("lib/aiweb/project/runtime_commands.rb") && line.include?("system(")
        return side_effect_classification("local_process_tree_cleanup", "documented_exception", nil, "taskkill/system calls are local cleanup fallbacks for preview process trees")
      end
      if path.end_with?("lib/aiweb/project/runtime_commands/qa_artifacts.rb") && line.include?("Open3.capture3")
        return side_effect_classification("local_qa_artifact_runner", "documented_exception", nil, "QA artifact subprocess is a local static/browser verification command writing run evidence")
      end
      if path.end_with?("lib/aiweb/project/engine_run.rb") && line.include?("Open3.popen3")
        return side_effect_classification("brokered_engine_run_capture_command", "brokered", "aiweb.engine_run.tool_broker", "engine_run_capture_command is invoked with staged tool-broker PATH and emits workspace tool-broker events")
      end
      if path.end_with?("lib/aiweb/project/engine_run.rb") && line.match?(/exec "\$dir\/\$TOOL_NAME"/)
        return side_effect_classification("brokered_generated_tool_broker_delegate", "brokered", "aiweb.engine_run.tool_broker", "generated POSIX tool-broker shim delegates only after package/git/external-network block checks")
      end
      if path.end_with?("lib/aiweb/project/engine_run.rb") && line.include?("Process.spawn")
        return side_effect_classification("local_engine_run_preview_server", "documented_exception", nil, "engine-run preview server is a local subprocess with stdout/stderr evidence and localhost URL probing")
      end
      if path.end_with?("lib/aiweb/project/engine_run.rb") && line.include?("Open3.capture3")
        return side_effect_classification("sandbox_runtime_attestation_exception", "documented_exception", nil, "Docker/Podman inspect/info/rm commands are local runtime-attestation probes, redacted, and recorded in sandbox-preflight evidence")
      end
      if path.end_with?("lib/aiweb/project/workbench.rb") && line.include?("Process.spawn")
        return side_effect_classification("local_workbench_server_process", "documented_exception", nil, "workbench serve starts a local development server with stdout/stderr logs")
      end
      if path.end_with?("lib/aiweb/project/agent_run.rb") && line.match?(/git.*diff|git.*status/)
        return side_effect_classification("local_read_only_git_evidence", "documented_exception", nil, "git diff/status subprocesses are local read-only evidence collection for bounded agent-run")
      end
      if path.end_with?("lib/aiweb/project/agent_run.rb") && line.include?("Open3.capture3")
        return side_effect_classification("legacy_agent_run_worker_subprocess", "documented_exception", nil, "legacy agent-run worker subprocess is bounded by agent-run context and OpenManus tool-broker log evidence; not a universal broker path")
      end
      if path.end_with?("lib/aiweb/project/runtime_commands.rb") && line.include?("Open3.capture3")
        return side_effect_classification("local_runtime_command_exception", "documented_exception", nil, "verify/QA/git revision subprocesses are project-local runtime commands; setup install commands are separately brokered")
      end
      if path.end_with?("lib/aiweb/daemon/openmanus_readiness.rb") && line.include?("Open3.capture3")
        return side_effect_classification("local_runtime_readiness_probe", "documented_exception", nil, "OpenManus readiness only inspects local Docker/Podman image availability")
      end
      side_effect_classification("unclassified_direct_side_effect", "unclassified", nil, "direct process/network surface is not yet classified by side-effect broker audit")
    end

    def side_effect_surface_safe_launcher_exec?(path, line)
      case path
      when "aiweb"
        line.include?('"$DIR/bin/aiweb" "$@"')
      when "웹빌더"
        line.include?('"$DIR/bin/webbuilder" "$@"')
      else
        false
      end
    end

    def side_effect_classification(classification, coverage_status, broker, rationale)
      {
        "classification" => classification,
        "coverage_status" => coverage_status,
        "broker" => broker,
        "rationale" => rationale
      }
    end
  end
end
