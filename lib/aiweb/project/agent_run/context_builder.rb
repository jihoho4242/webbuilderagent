# frozen_string_literal: true

module Aiweb
  module ProjectAgentRun
    private

    def agent_run_context_manifest(task_source:, design_text:, component_map_text:, source_paths:, target_allowlist: nil)
      context_files = []

      if task_source["path"]
        context_files << agent_run_context_file(task_source["path"], "task")
      end

      design_path = File.join(aiweb_dir, "DESIGN.md")
      if File.file?(design_path)
        context_files << agent_run_context_file(design_path, "design")
      end

      component_map_path = File.join(aiweb_dir, "component-map.json")
      if File.file?(component_map_path)
        context_files << agent_run_context_file(component_map_path, "component_map")
      end

      selected = selected_candidate_id
      selected_design_files = []
      if selected
        selected_md = File.join(aiweb_dir, "design-candidates", "selected.md")
        candidate_html = File.join(aiweb_dir, "design-candidates", "#{selected}.html")
        candidate_md = File.join(aiweb_dir, "design-candidates", "#{selected}.md")
        selected_design_files << agent_run_context_file(selected_md, "selected_design") if File.file?(selected_md)
        if File.file?(candidate_html)
          selected_design_files << agent_run_context_file(candidate_html, "selected_candidate")
        elsif File.file?(candidate_md)
          selected_design_files << agent_run_context_file(candidate_md, "selected_candidate")
        end
        context_files.concat(selected_design_files)
      end

      source_files = source_paths.map { |path| agent_run_context_file(path, "source") }
      {
        "task" => task_source["path"] ? agent_run_context_file(task_source["path"], "task") : nil,
        "design" => design_text ? agent_run_context_file(design_path, "design") : nil,
        "component_map" => component_map_text ? agent_run_context_file(component_map_path, "component_map") : nil,
        "selected_candidate" => selected,
        "selected_design_files" => selected_design_files,
        "source_files" => source_files,
        "context_files" => context_files.compact,
        "source_paths" => source_paths,
        "target_allowlist" => target_allowlist,
        "targeted_edit" => !!target_allowlist,
        "safe_context_only" => true
      }
    end

    def agent_run_context_file(path, kind)
      expanded = File.expand_path(path, root)
      {
        "kind" => kind,
        "path" => relative(expanded),
        "bytes" => File.size(expanded),
        "sha256" => Digest::SHA256.file(expanded).hexdigest,
        "content" => File.read(expanded)
      }
    rescue SystemCallError
      {
        "kind" => kind,
        "path" => relative(path),
        "bytes" => nil,
        "sha256" => nil,
        "content" => nil
      }
    end

    def agent_run_prompt(context:)
      lines = []
      lines << "You are the local source-patch agent for aiweb."
      lines << "Follow AGENTS.md and patch only the approved source files listed below."
      lines << "Do not read or print .env or .env.* files."
      lines << "Do not run build, preview, QA, deploy, or package install commands."
      lines << ""
      lines << "## Task packet"
      lines << (context["task"] && context["task"]["content"]).to_s
      if context["design"] && context["design"]["content"]
        lines << ""
        lines << "## DESIGN.md"
        lines << context["design"]["content"].to_s
      end
      if context["component_map"] && context["component_map"]["content"]
        lines << ""
        lines << "## component-map.json"
        lines << context["component_map"]["content"].to_s
      end
      if context["target_allowlist"]
        lines << ""
        lines << "## Targeted visual edit allowlist"
        lines << JSON.pretty_generate(context["target_allowlist"])
      end
      if context["selected_candidate"]
        lines << ""
        lines << "## Selected design"
        lines << "Selected candidate: #{context["selected_candidate"]}"
        Array(context["selected_design_files"]).each do |file|
          lines << ""
          lines << "### #{file["path"]}"
          lines << file["content"].to_s
        end
      end
      Array(context["source_files"]).each do |file|
        lines << ""
        lines << "## #{file["path"]}"
        lines << file["content"].to_s
      end
      lines << ""
      lines << "## Instructions"
      lines << "- Make the minimal safe source patch needed for the task."
      if context["target_allowlist"]
        lines << "- Patch only the strict source_paths listed in the targeted visual edit allowlist."
        lines << "- Do not regenerate the full page."
        lines << "- Do not edit unrelated components or pages even if they appear in component-map.json."
      end
      lines << "- Leave .ai-web run artifacts, logs, and diff evidence to the wrapper."
      lines << "- Return by exiting after the patch is complete."
      lines.join("\n")
    end
  end
end
