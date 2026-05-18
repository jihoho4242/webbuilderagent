# frozen_string_literal: true

module Aiweb
  class Project
    private

    def visual_critique_evidence_paths(paths, evidence_paths, screenshot, screenshots, metadata)
      requested = [paths, evidence_paths, screenshot, screenshots, metadata].flatten.compact.map(&:to_s).map(&:strip).reject(&:empty?)
      expanded = []
      requested.each do |path|
        if path == "latest" && [screenshots, metadata].flatten.compact.map(&:to_s).map(&:strip).include?("latest")
          expanded.concat(latest_qa_screenshot_evidence_paths)
        else
          expanded << path
        end
      end
      expanded.uniq
    end

    def latest_qa_screenshot_evidence_paths
      state = load_state_if_present
      latest = state&.dig("qa", "latest_screenshot_metadata").to_s.strip
      latest = File.join(".ai-web", "qa", "screenshots", "metadata.json") if latest.empty?
      metadata_path = File.expand_path(latest, root)
      return [latest] unless File.file?(metadata_path)

      metadata = JSON.parse(File.read(metadata_path))
      screenshots = metadata["screenshots"]
      items = if screenshots.is_a?(Hash)
                %w[desktop tablet mobile].map { |name| screenshots[name] }.compact
              else
                Array(screenshots)
              end
      paths = items.map { |item| item.is_a?(Hash) ? item["path"].to_s.strip : "" }.reject(&:empty?)
      paths << relative(metadata_path)
      paths
    rescue JSON::ParserError
      [latest]
    end

    def validate_visual_critique_input_path!(path)
      raise UserError.new("visual-critique evidence path must be local: #{path}", 1) if path.match?(/\A[a-z][a-z0-9+.-]*:\/\//i)
      reject_env_file_segment!(path, "visual-critique refuses to read .env or .env.* evidence paths")

      expanded = File.expand_path(path, root)
      unless File.file?(expanded)
        raise UserError.new("visual-critique evidence path does not exist or is not a file: #{path}", 1)
      end
    end

    def visual_critique_record(critique_id:, task_id:, evidence_paths:, artifact_path:, dry_run:)
      evidence = evidence_paths.map { |path| visual_critique_evidence(path) }
      fixture = visual_critique_fixture(evidence)
      scores = visual_critique_scores(evidence, fixture)
      issues = visual_critique_issues(scores, fixture)
      patch_plan = visual_critique_patch_plan(scores, issues)
      approval = visual_critique_approval(scores, issues)
      screenshot_evidence = evidence.find { |item| item["kind"] == "screenshot" }
      metadata_evidence = evidence.find { |item| item["kind"] == "metadata" }
      status = if dry_run
        "dry_run"
      elsif approval == "pass"
        "passed"
      else
        "failed"
      end
      artifact_relative = relative(artifact_path)
      {
        "schema_version" => 1,
        "type" => "visual_critique",
        "id" => critique_id,
        "task_id" => task_id.to_s.empty? ? critique_id : task_id.to_s,
        "status" => status,
        "dry_run" => dry_run,
        "created_at" => now,
        "artifact" => artifact_relative,
        "artifact_path" => artifact_relative,
        "screenshot_path" => screenshot_evidence && screenshot_evidence["path"],
        "metadata_path" => metadata_evidence && metadata_evidence["path"],
        "design_contract" => design_contract_context,
        "evidence" => evidence,
        "scores" => scores,
        "hierarchy" => scores.fetch("hierarchy"),
        "typography" => scores.fetch("typography"),
        "spacing" => scores.fetch("spacing"),
        "color" => scores.fetch("color"),
        "originality" => scores.fetch("originality"),
        "mobile_polish" => scores.fetch("mobile_polish"),
        "brand_fit" => scores.fetch("brand_fit"),
        "intent_fit" => scores.fetch("intent_fit"),
        "issues" => issues,
        "patch_plan" => patch_plan,
        "approval" => approval,
        "guardrails" => [
          "use screenshots and metadata as local evidence only",
          "compare against .ai-web/DESIGN.md and selected candidate context when present",
          "do not copy external references, screenshots, copy, prices, trademarks, or brand claims",
          "do not read .env or .env.*"
        ]
      }
    end

    def design_contract_context
      design_path = File.join(aiweb_dir, "DESIGN.md")
      reference_path = File.join(aiweb_dir, "design-reference-brief.md")
      selected = selected_candidate_id
      state = load_state_if_present
      selected_path = selected && state && selected_candidate_artifact_path(state, selected)
      {
        "design_path" => File.file?(design_path) ? relative(design_path) : nil,
        "design_sha256" => File.file?(design_path) ? Digest::SHA256.file(design_path).hexdigest : nil,
        "reference_brief_path" => File.file?(reference_path) ? relative(reference_path) : nil,
        "reference_brief_sha256" => File.file?(reference_path) ? Digest::SHA256.file(reference_path).hexdigest : nil,
        "selected_candidate" => selected,
        "selected_candidate_path" => selected_path && File.file?(selected_path) ? relative(selected_path) : nil,
        "selected_candidate_sha256" => selected_path && File.file?(selected_path) ? Digest::SHA256.file(selected_path).hexdigest : nil
      }.compact
    rescue SystemCallError
      {}
    end

    def visual_critique_evidence(path)
      expanded = File.expand_path(path, root)
      stat = File.stat(expanded)
      {
        "path" => relative(expanded),
        "bytes" => stat.size,
        "sha256" => Digest::SHA256.file(expanded).hexdigest,
        "kind" => visual_critique_evidence_kind(expanded)
      }
    end

    def visual_critique_evidence_kind(path)
      case File.extname(path).downcase
      when ".png", ".jpg", ".jpeg", ".webp", ".gif", ".avif", ".svg" then "screenshot"
      when ".json", ".yml", ".yaml", ".txt", ".md" then "metadata"
      else "file"
      end
    end

    def visual_critique_fixture(evidence)
      evidence.each do |item|
        path = File.join(root, item.fetch("path"))
        next unless item["kind"] == "metadata"

        parsed = parse_visual_critique_fixture(path)
        return parsed if parsed.is_a?(Hash)
      end
      {}
    end

    def parse_visual_critique_fixture(path)
      content = File.read(path, 64 * 1024)
      case File.extname(path).downcase
      when ".json"
        JSON.parse(content)
      when ".yml", ".yaml"
        YAML.safe_load(content, permitted_classes: [Time], aliases: false) || {}
      else
        { "notes" => content }
      end
    rescue JSON::ParserError, Psych::Exception
      { "notes" => content.to_s }
    end

    def visual_critique_scores(evidence, fixture)
      categories = visual_critique_score_categories
      explicit = fixture["visual_critique"] || fixture["scores"] || fixture
      scores = categories.each_with_object({}) do |category, memo|
        value = explicit[category] if explicit.is_a?(Hash)
        memo[category] = clamp_score(value || visual_critique_default_score(category, evidence, fixture))
      end
      scores
    end

    def visual_critique_score_categories
      %w[first_impression hierarchy typography layout_rhythm spacing color originality mobile_polish brand_fit intent_fit content_credibility interaction_clarity]
    end

    def visual_critique_default_score(category, evidence, fixture)
      notes = fixture["notes"].to_s.downcase
      score = 72
      score += 5 if evidence.any? { |item| item["kind"] == "screenshot" }
      score += 3 if evidence.any? { |item| item["kind"] == "metadata" }
      score -= 25 if notes.match?(/broken|fail|poor|low|clutter|illegible|generic|misaligned|overflow/)
      score -= 10 if category == "mobile_polish" && notes.match?(/mobile|responsive|viewport/)
      score -= 8 if category == "originality" && notes.match?(/generic|template|stock/)
      score -= 8 if category == "brand_fit" && notes.match?(/brand|tone|voice/)
      score -= 8 if category == "intent_fit" && notes.match?(/intent|goal|audience/)
      score
    end

    def clamp_score(value)
      numeric = value.is_a?(String) ? value.to_f : value.to_f
      [[numeric.round, 0].max, 100].min
    end

    def visual_critique_issues(scores, fixture)
      explicit = fixture["issues"]
      return explicit.map(&:to_s) if explicit.is_a?(Array) && !explicit.empty?

      thresholds = visual_critique_gate_thresholds
      axis_floor = thresholds.fetch("min_axis")
      average_floor = thresholds.fetch("min_average")
      low = scores.select { |_category, score| score < axis_floor }
      average = scores.empty? ? 0.0 : scores.values.sum.to_f / scores.length
      issues = low.map { |category, score| "#{category.tr("_", " ")} score #{score} is below the visual quality target #{axis_floor.to_i}" }
      if average < average_floor
        issues << "average visual score #{format('%.1f', average)} is below the visual quality target #{average_floor.to_i}"
      end
      return [] if issues.empty?

      issues
    end

    def visual_critique_patch_plan(scores, issues)
      return [] if issues.empty?

      axis_floor = visual_critique_gate_thresholds.fetch("min_axis")
      plan = scores.select { |_category, score| score < axis_floor }.map do |category, score|
        {
          "area" => category,
          "priority" => score < 50 ? "high" : "medium",
          "action" => visual_critique_patch_action(category)
        }
      end
      if plan.empty?
        plan << {
          "area" => "overall_visual_quality",
          "priority" => "medium",
          "action" => "raise the average visual quality through stronger first-view composition, contrast, spacing, and source-backed proof"
        }
      end
      plan
    end

    def visual_critique_patch_action(category)
      case category
      when "first_impression" then "tighten first-view composition, value clarity, and brand signal"
      when "hierarchy" then "clarify primary headline, CTA emphasis, and section order"
      when "layout_rhythm" then "rebalance section rhythm, composition changes, and scan path"
      when "typography" then "tighten type scale, line height, and readable contrast"
      when "spacing" then "normalize section rhythm, gutters, and component padding"
      when "color" then "reduce palette noise and improve semantic color contrast"
      when "originality" then "add distinctive composition, imagery, or interaction motif"
      when "mobile_polish" then "verify responsive spacing, tap targets, and above-the-fold composition"
      when "brand_fit" then "align tone, visual motifs, and UI details with brand attributes"
      when "intent_fit" then "make the page goal and user journey more explicit"
      when "content_credibility" then "remove unsupported claims and improve source-backed proof hierarchy"
      when "interaction_clarity" then "clarify CTA states, forms, and navigation affordances"
      else "improve visual quality for #{category.tr("_", " ")}"
      end
    end

    def visual_critique_approval(scores, issues)
      minimum = scores.values.min || 0
      average = scores.empty? ? 0.0 : scores.values.sum.to_f / scores.length
      thresholds = visual_critique_gate_thresholds
      return "redesign" if minimum < 50 || average < 60
      return "repair" if minimum < thresholds.fetch("min_axis") || average < thresholds.fetch("min_average") || !issues.empty?

      "pass"
    end

    def visual_critique_gate_thresholds
      quality = File.file?(quality_path) ? YAML.load_file(quality_path) : {}
      gate = quality.dig("quality", "design", "phase_0_gate") if quality.is_a?(Hash)
      gate = {} unless gate.is_a?(Hash)
      {
        "min_axis" => [gate["min_visual_score_axis"].to_f, 70.0].max,
        "min_average" => [gate["min_visual_score_average"].to_f, 75.0].max
      }
    rescue Psych::Exception, SystemCallError
      { "min_axis" => 75.0, "min_average" => 75.0 }
    end

    def visual_critique_payload(state:, critique:, changed_files:, planned_changes:, action_taken:, next_action:)
      blockers = critique["approval"] == "pass" ? [] : ["visual critique approval=#{critique["approval"]}"]
      {
        "schema_version" => 1,
        "current_phase" => state&.dig("phase", "current"),
        "action_taken" => action_taken,
        "dry_run" => critique["dry_run"],
        "changed_files" => changed_files,
        "planned_changes" => planned_changes,
        "blocking_issues" => blockers,
        "missing_artifacts" => [],
        "visual_critique" => critique,
        "next_action" => next_action
      }
    end

    def visual_critique_next_action(critique)
      case critique["approval"]
      when "pass" then "use #{critique["artifact"]} as local visual critique evidence"
      when "repair" then "review patch_plan in #{critique["artifact"]}, make targeted visual edits, then rerun aiweb visual-critique"
      else "review issues in #{critique["artifact"]}, redesign the weak areas, then rerun aiweb visual-critique"
      end
    end


  end
end
