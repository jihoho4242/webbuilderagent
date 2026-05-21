# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    private

    def engine_run_eval_human_calibration(design_fixture)
      fixture_id = design_fixture.to_h["fixture_id"].to_s
      path = File.join(root, ".ai-web", "eval", "human-baselines.json")
      return engine_run_seeded_human_calibration(path, design_fixture) unless File.file?(path)

      data = JSON.parse(File.read(path, 256 * 1024))
      fixture_baseline = data.dig("fixtures", fixture_id) || Array(data["fixtures"]).find { |entry| entry.is_a?(Hash) && entry["fixture_id"].to_s == fixture_id }
      return engine_run_seeded_human_calibration(path, design_fixture) unless fixture_baseline.is_a?(Hash)

      issues = engine_run_eval_human_baseline_issues(fixture_baseline, fixture_id)
      unless issues.empty?
        return {
          "status" => "invalid",
          "baseline_source" => {
            "type" => "human_baseline",
            "path" => relative(path),
            "fixture_id" => fixture_id,
            "status" => "invalid",
            "issues" => issues
          }
        }
      end

      human_ratings = Array(fixture_baseline["human_ratings"]).select { |entry| entry.is_a?(Hash) }
      human_scores = fixture_baseline["human_scores"].is_a?(Hash) ? fixture_baseline["human_scores"] : {}
      reviewer_count = if fixture_baseline["reviewer_count"].is_a?(Integer)
                         fixture_baseline["reviewer_count"]
                       else
                         human_ratings.length
                       end
      calibrated = (!human_scores.empty? || !human_ratings.empty?) && reviewer_count.positive?
      {
        "status" => calibrated ? "calibrated" : "seeded",
        "baseline_source" => {
          "type" => "human_baseline",
          "path" => relative(path),
          "status" => "ready",
          "fixture_id" => fixture_id,
          "average_score" => fixture_baseline["average_score"],
          "reviewer_count" => reviewer_count,
          "score_axes" => human_scores.keys.sort,
          "rating_count" => human_ratings.length
        }
      }
    rescue JSON::ParserError, SystemCallError => e
      {
        "status" => "missing",
        "baseline_source" => {
          "type" => "human_baseline",
          "path" => relative(path),
          "status" => "unreadable",
          "reason" => e.message
        }
      }
    end

    def engine_run_eval_human_baseline_issues(fixture_baseline, fixture_id)
      issues = []
      if fixture_baseline["fixture_id"] && fixture_baseline["fixture_id"].to_s != fixture_id
        issues << "human baseline fixture_id does not match design fixture"
      end
      average = fixture_baseline["average_score"]
      issues << "human baseline average_score must be numeric 0..100" unless average.is_a?(Numeric) && average >= 0 && average <= 100
      if fixture_baseline.key?("reviewer_count") && (!fixture_baseline["reviewer_count"].is_a?(Integer) || fixture_baseline["reviewer_count"].negative?)
        issues << "human baseline reviewer_count must be a non-negative integer"
      end
      if fixture_baseline.key?("human_scores")
        scores = fixture_baseline["human_scores"]
        if !scores.is_a?(Hash) || scores.empty?
          issues << "human baseline human_scores must be a non-empty object when present"
        else
          scores.each do |axis, value|
            issues << "human baseline score #{axis} must be numeric 0..100" unless value.is_a?(Numeric) && value >= 0 && value <= 100
          end
        end
      end
      if fixture_baseline.key?("human_ratings")
        ratings = fixture_baseline["human_ratings"]
        if !ratings.is_a?(Array) || ratings.empty?
          issues << "human baseline human_ratings must be a non-empty array when present"
        else
          ratings.each_with_index do |rating, index|
            unless rating.is_a?(Hash)
              issues << "human baseline rating #{index} must be an object"
              next
            end
            score = rating["overall_score"]
            scores = rating["scores"]
            if score && !(score.is_a?(Numeric) && score >= 0 && score <= 100)
              issues << "human baseline rating #{index} overall_score must be numeric 0..100"
            end
            if scores && (!scores.is_a?(Hash) || scores.values.any? { |value| !value.is_a?(Numeric) || value < 0 || value > 100 })
              issues << "human baseline rating #{index} scores must be numeric 0..100"
            end
          end
        end
      end
      serialized_fixture_baseline = json_generate(fixture_baseline)
      if serialized_fixture_baseline.match?(ENGINE_RUN_SECRET_VALUE_PATTERN) || serialized_fixture_baseline.match?(/\b[A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PRIVATE[_-]?KEY|API[_-]?KEY|CREDENTIAL)[A-Z0-9_]*=/i)
        issues << "human baseline must not contain raw secrets or environment values"
      end
      issues.uniq
    end
  end
end
