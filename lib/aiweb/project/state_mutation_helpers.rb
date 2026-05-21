# frozen_string_literal: true

require "fileutils"

module Aiweb
  module ProjectStateMutationHelpers
    private

    def ensure_setup_state_defaults!(state)
      state["setup"] ||= {}
      state["setup"]["latest_run"] = nil unless state["setup"].key?("latest_run")
      state["setup"]["package_manager"] = nil unless state["setup"].key?("package_manager")
      state["setup"]["node_modules_present"] = false if state["setup"]["node_modules_present"].nil?
      state["setup"]["last_installed_at"] = nil unless state["setup"].key?("last_installed_at")
      state
    end

    def ensure_implementation_state_defaults!(state)
      state["implementation"] ||= {}
      state["implementation"]["latest_agent_run"] = nil unless state["implementation"].key?("latest_agent_run")
      state["implementation"]["last_diff"] = nil unless state["implementation"].key?("last_diff")
      state
    end

    def upsert_candidate(current, ref)
      replaced = false
      updated = current.map do |item|
        if item["id"] == ref["id"]
          replaced = true
          item.merge(ref)
        else
          item
        end
      end
      updated << ref unless replaced
      updated
    end

    def recommended_task_type(state)
      case state.dig("phase", "current")
      when "phase-6" then "bootstrap"
      when "phase-7" then "design-tokens"
      when "phase-8" then "golden-page"
      when "phase-9" then "remaining-pages-features"
      when "phase-11" then "deploy-preparation"
      else "phase-#{state.dig("phase", "current")}-work"
      end
    end

    def add_decision!(state, type, summary)
      state["decisions"] ||= []
      state["decisions"] << {
        "id" => "decision-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}",
        "type" => type,
        "summary" => summary,
        "created_at" => now
      }
    end

    def copy_snapshot_contents(snapshot_dir)
      Dir.children(aiweb_dir).each do |entry|
        next if entry == "snapshots" || entry == ".lock"
        src = File.join(aiweb_dir, entry)
        dest = File.join(snapshot_dir, entry)
        if File.directory?(src)
          FileUtils.cp_r(src, dest)
        else
          FileUtils.cp(src, dest)
        end
      end
    end
  end
end
