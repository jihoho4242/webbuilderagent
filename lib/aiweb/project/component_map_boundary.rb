# frozen_string_literal: true

module Aiweb
  class Project
    private

    def load_json_file(path)
      reject_env_file_segment!(path, "refusing to read .env or .env.* JSON path")

      JSON.parse(File.read(File.expand_path(path, root)))
    rescue JSON::ParserError => e
      raise UserError.new("cannot parse JSON #{path}: #{e.message}", 1)
    end

    def component_map_source_paths
      candidates = SCAFFOLD_PROFILE_D_REQUIRED_FILES.grep(%r{\Asrc/})
      candidates.select do |relative_path|
        path = File.join(root, relative_path)
        File.file?(path) && safe_component_map_scan_path?(relative_path)
      end
    end

    def safe_component_map_scan_path?(relative_path)
      normalized = relative_path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
      parts = normalized.split("/")

      return false if normalized.empty? || normalized.start_with?("/")
      return false if parts.any? { |part| part == ".." || part.start_with?(".env") }
      return false if parts.any? { |part| %w[node_modules dist build coverage tmp vendor .git].include?(part) }

      normalized.start_with?("src/")
    end

    def discover_component_map_components
      component_map_source_paths.flat_map do |relative_path|
        path = File.join(root, relative_path)
        discover_component_map_components_in_file(path, relative_path)
      end.sort_by { |component| [component["source_path"].to_s, component["line"].to_i, component["data_aiweb_id"].to_s] }
    end

    def discover_component_map_components_in_file(path, relative_path)
      body = File.read(path)
      components = []
      body.lines.each_with_index do |line, index|
        line.scan(/data-aiweb-id\s*=\s*["']([^"']+)["']/) do |match|
          components << component_map_component_record(match.first, relative_path, line, index + 1, "data-aiweb-id")
        end
        line.scan(/\baiwebId\s*=\s*["']([^"']+)["']/) do |match|
          components << component_map_component_record(match.first, relative_path, line, index + 1, "aiwebId-prop")
        end
      end
      components.uniq { |component| [component["data_aiweb_id"], component["source_path"], component["line"]] }
    rescue SystemCallError
      []
    end

    def component_map_component_record(data_aiweb_id, relative_path, line, line_number, source_hook)
      {
        "data_aiweb_id" => data_aiweb_id.to_s,
        "source_path" => relative_path,
        "kind" => component_map_kind(relative_path, data_aiweb_id),
        "route" => component_map_route(relative_path, data_aiweb_id),
        "editable" => true,
        "line" => line_number,
        "source_hook" => source_hook,
        "snippet_summary" => component_map_snippet_summary(line)
      }
    end

    def component_map_kind(relative_path, data_aiweb_id)
      return "page" if relative_path.start_with?("src/pages/") || data_aiweb_id.to_s.start_with?("page.", "document.")
      return "component" if relative_path.start_with?("src/components/") || data_aiweb_id.to_s.start_with?("component.")

      "region"
    end

    def component_map_route(relative_path, data_aiweb_id)
      return "/" if relative_path == "src/pages/index.astro" || data_aiweb_id.to_s.include?(".home")
      if relative_path.start_with?("src/pages/")
        page = relative_path.sub(%r{\Asrc/pages/}, "").sub(/\.astro\z/, "")
        return "/" if page == "index"

        return "/#{page.sub(%r{/index\z}, "")}"
      end

      nil
    end

    def component_map_snippet_summary(line)
      tag = line.to_s[/<\s*([A-Za-z][A-Za-z0-9:-]*)/, 1]
      classes = line.to_s[/class\s*=\s*"([^"]{0,80})"/, 1] || line.to_s[/class\s*=\s*'([^']{0,80})'/, 1]
      [tag ? "tag=#{tag}" : nil, classes ? "class=#{classes}" : nil].compact.join("; ")
    end

    def component_map_blockers(components, force:)
      missing = SCAFFOLD_PROFILE_D_REQUIRED_FILES.grep(%r{\Asrc/}).reject { |path| File.file?(File.join(root, path)) }
      blockers = []
      blockers << "scaffold/source files are missing: #{missing.join(", ")}" unless missing.empty?
      blockers << "no stable data-aiweb-id hooks found in scaffold/source files" if components.empty?
      blockers
    end

    def component_map_record(status:, artifact_path:, components:, blockers:, dry_run:)
      {
        "schema_version" => 1,
        "status" => status,
        "artifact_path" => relative(artifact_path),
        "generated_at" => dry_run ? nil : now,
        "dry_run" => dry_run,
        "source_root" => ".",
        "scan" => {
          "included_paths" => component_map_source_paths,
          "excluded_patterns" => [".env", ".env.*", "node_modules", "dist", "build", "coverage", "tmp", "vendor/bundle"],
          "source_contents_embedded" => false
        },
        "components" => components,
        "blocking_issues" => blockers
      }
    end

    def component_map_payload(state:, component_map:, changed_files:, planned_changes:, action_taken:, blocking_issues:, next_action:)
      payload = status_hash(state: state, changed_files: changed_files)
      payload["action_taken"] = action_taken
      payload["blocking_issues"] = blocking_issues
      payload["planned_changes"] = planned_changes unless planned_changes.empty?
      payload["component_map"] = component_map
      payload["next_action"] = next_action
      payload
    end

    def resolve_component_map_source(from_map)
      raw = from_map.to_s.strip
      raw = "latest" if raw.empty?
      return { "path" => File.join(aiweb_dir, "component-map.json"), "relative" => ".ai-web/component-map.json", "error" => nil } if raw == "latest"

      normalized = raw.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
      parts = normalized.split("/")
      error = if raw.match?(/\A[a-z][a-z0-9+.-]*:\/\//i) || raw.start_with?("/") || raw.match?(%r{\A[A-Za-z]:[\\/]})
                "component map path must be a local project-relative path"
              elsif parts.any? { |part| part == ".." }
                "component map path must not contain traversal"
              elsif parts.any? { |part| part.start_with?(".env") }
                "component map path must not reference .env files"
              elsif !normalized.start_with?(".ai-web/")
                "component map path must stay under .ai-web"
              end
      return { "path" => nil, "relative" => normalized, "error" => error } if error

      { "path" => File.join(root, normalized), "relative" => normalized, "error" => nil }
    end

    def load_component_map_for_visual_edit(path)
      data = JSON.parse(File.read(path))
      raise UserError.new("component map must be a JSON object", 1) unless data.is_a?(Hash)

      data
    rescue Errno::ENOENT
      nil
    rescue JSON::ParserError => e
      raise UserError.new("cannot parse component map: #{e.message}", 1)
    end

    def component_map_component(component_map, target)
      matches = component_map_components(component_map, target)
      matches.length == 1 ? matches.first : nil
    end

    def component_map_components(component_map, target)
      Array(component_map["components"]).select { |component| component.is_a?(Hash) && component["data_aiweb_id"].to_s == target }
    end

  end
end
