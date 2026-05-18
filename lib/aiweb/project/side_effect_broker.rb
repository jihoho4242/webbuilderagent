# frozen_string_literal: true

require "ripper"
require_relative "side_effect_broker/classification"

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
      Aiweb::Redaction.redact_command(command)
    end

    def redact_side_effect_process_output(text)
      Aiweb::Redaction.redact_process_output(text, base_redactor: ->(value) { agent_run_redact_process_output(value) })
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
      return [] if rel.end_with?("lib/aiweb/project/side_effect_broker.rb") || rel.include?("lib/aiweb/project/side_effect_broker/")

      lines = File.readlines(path, chomp: true)
      regex_entries = lines.each_with_index.filter_map do |line, index|
        next if side_effect_surface_comment_line?(line)

        matched = SIDE_EFFECT_SURFACE_PATTERNS.find { |pattern| line.match?(pattern) }
        next unless matched

        side_effect_surface_entry(rel, source, index + 1, matched.source, line, lines, index)
      end
      (regex_entries + side_effect_surface_backtick_entries_for(rel, source, lines) + side_effect_surface_command_form_entries_for(rel, source, lines))
        .uniq { |entry| side_effect_surface_entry_key(entry) }
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

    def side_effect_surface_entry_key(entry)
      [
        entry.fetch("path"),
        entry.fetch("line"),
        side_effect_surface_pattern_family(entry.fetch("pattern"), entry.fetch("snippet", ""))
      ]
    end

    def side_effect_surface_pattern_family(pattern, snippet)
      pattern = pattern.to_s
      snippet = snippet.to_s
      return "ruby_system" if pattern.include?("ruby_command_form_system")
      return "ruby_spawn" if pattern.include?("ruby_command_form_spawn")
      return "ruby_exec" if pattern.include?("ruby_command_form_exec")
      return "ruby_percent_x_command" if pattern == "ruby_percent_x_command"
      return "ruby_backtick_command" if pattern == "ruby_backtick_command"
      return "open3" if pattern.include?("Open3")
      return "net_http" if pattern.include?("Net::HTTP")
      return "io_popen" if pattern.include?("IO\\.popen")
      return "process_spawn" if pattern.include?("Process\\.spawn") || snippet.match?(/\bProcess\.spawn\b/)
      return "ruby_system" if snippet.match?(/(?<![.\w-])system\b|\bKernel\.system\b/) || pattern.include?("system")
      return "ruby_spawn" if snippet.match?(/(?<![.\w-])spawn\b|\bKernel\.spawn\b/) || pattern.include?("spawn")
      return "ruby_exec" if snippet.match?(/(?<![.\w-])exec\b|\bKernel\.exec\b/) || pattern.include?("exec")

      pattern
    end

    def side_effect_surface_relative(path, base_root)
      base = File.expand_path(base_root.to_s)
      full = File.expand_path(path.to_s)
      rel = full.sub(/^#{Regexp.escape(base)}[\/\\]?/, "")
      rel.tr("\\", "/")
    end


  end
end
