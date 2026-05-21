# frozen_string_literal: true

require_relative "supply_chain/broker"
require_relative "supply_chain/lockfile"
require_relative "supply_chain/plan"
require_relative "supply_chain/network_policy"
require_relative "supply_chain/audit_exception"
require_relative "supply_chain/artifacts"

module Aiweb
  module ProjectRuntimeCommands
    private

    def setup_supply_chain_tracked_files
      %w[package.json pnpm-lock.yaml package-lock.json yarn.lock bun.lockb]
    end

    def setup_supply_chain_dependency_sections
      %w[dependencies devDependencies peerDependencies optionalDependencies]
    end

    def setup_supply_chain_file_snapshot
      setup_supply_chain_tracked_files.to_h do |relative_path|
        full_path = File.join(root, relative_path)
        if File.file?(full_path)
          [relative_path, {
            "present" => true,
            "bytes" => File.size(full_path),
            "sha256" => Digest::SHA256.file(full_path).hexdigest
          }]
        else
          [relative_path, { "present" => false }]
        end
      end
    end

    def setup_supply_chain_dependency_snapshot
      path = File.join(root, "package.json")
      return {
        "status" => "missing",
        "path" => "package.json",
        "sections" => setup_supply_chain_empty_dependency_sections,
        "network_refs" => [],
        "network_allowlist_violations" => []
      } unless File.file?(path)

      data = JSON.parse(File.read(path))
      unless data.is_a?(Hash)
        return {
          "status" => "invalid",
          "path" => "package.json",
          "error" => "package.json root is not an object",
          "sections" => setup_supply_chain_empty_dependency_sections,
          "network_refs" => [],
          "network_allowlist_violations" => []
        }
      end

      sections = setup_supply_chain_dependency_sections.to_h do |section|
        values = data[section].is_a?(Hash) ? data[section] : {}
        [section, values.keys.sort.to_h { |name| [name, setup_supply_chain_redact_dependency_specifier(values[name].to_s)] }]
      end
      network_refs = setup_supply_chain_dependency_network_refs(sections)
      {
        "status" => "parsed",
        "path" => "package.json",
        "package_name" => data["name"].to_s.empty? ? nil : data["name"].to_s,
          "package_version" => data["version"].to_s.empty? ? nil : data["version"].to_s,
          "sections" => sections,
          "malformed_sections" => setup_supply_chain_dependency_sections.select { |section| data.key?(section) && !data[section].is_a?(Hash) },
          "network_refs" => network_refs,
          "network_allowlist_violations" => setup_supply_chain_network_allowlist_violations(network_refs)
      }
    rescue JSON::ParserError => e
      {
        "status" => "invalid",
        "path" => "package.json",
        "error" => e.message,
        "sections" => setup_supply_chain_empty_dependency_sections,
        "network_refs" => [],
        "network_allowlist_violations" => []
      }
    rescue SystemCallError => e
      {
        "status" => "unreadable",
        "path" => "package.json",
        "error" => e.message,
        "sections" => setup_supply_chain_empty_dependency_sections,
        "network_refs" => [],
        "network_allowlist_violations" => []
      }
    end

    def setup_supply_chain_empty_dependency_sections
      setup_supply_chain_dependency_sections.to_h { |section| [section, {}] }
    end

    def setup_supply_chain_dependency_semantic_diff(before, after)
      added = []
      removed = []
      version_changes = []
      setup_supply_chain_dependency_sections.each do |section|
        before_values = before.dig("sections", section).is_a?(Hash) ? before.dig("sections", section) : {}
        after_values = after.dig("sections", section).is_a?(Hash) ? after.dig("sections", section) : {}
        (after_values.keys - before_values.keys).sort.each do |name|
          added << { "section" => section, "name" => name, "version" => after_values[name] }
        end
        (before_values.keys - after_values.keys).sort.each do |name|
          removed << { "section" => section, "name" => name, "version" => before_values[name] }
        end
        (before_values.keys & after_values.keys).sort.each do |name|
          next if before_values[name] == after_values[name]

          version_changes << {
            "section" => section,
            "name" => name,
            "before" => before_values[name],
            "after" => after_values[name]
          }
        end
      end
      changed = !(added.empty? && removed.empty? && version_changes.empty?)
      {
        "status" => changed ? "changed" : "unchanged",
        "before_status" => before["status"],
        "after_status" => after["status"],
        "sections" => setup_supply_chain_dependency_sections,
        "added" => added,
        "removed" => removed,
        "version_changes" => version_changes,
        "added_count" => added.length,
        "removed_count" => removed.length,
        "version_change_count" => version_changes.length
      }
    end

    def setup_post_install_package_manifest_blockers(dependency_semantic_after)
      blockers = []
      unless dependency_semantic_after["status"] == "parsed"
        blockers << "post-install package.json is #{dependency_semantic_after["status"]}; setup completion is blocked"
      end
      malformed_sections = Array(dependency_semantic_after["malformed_sections"])
      unless malformed_sections.empty?
        blockers << "post-install package.json has malformed dependency sections: #{malformed_sections.join(", ")}"
      end

      state, state_error = runtime_state_snapshot
      ensure_scaffold_state_defaults!(state) if state
      scaffold = runtime_scaffold_summary(state)
      contract = runtime_profile_contract(scaffold)
      metadata = runtime_metadata_summary(scaffold)
      design = runtime_design_summary(state, metadata)
      package_json = runtime_package_json_summary(contract)
      missing_files = runtime_missing_required_files(contract)
      package_blockers = runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files, contract).select do |issue|
        issue.to_s.match?(/package\.json|package manager|dependency|script|lockfile/i)
      end
      package_blockers.each do |issue|
        blockers << "post-install package manifest failed runtime-plan validation: #{issue}"
      end
      blockers.uniq
    end

    def setup_post_install_lockfile_blockers(package_manager, lockfile_semantic_after)
      return [] unless package_manager == "pnpm"
      return [] if lockfile_semantic_after["status"] == "parsed"

      [
        "post-install pnpm-lock.yaml is #{lockfile_semantic_after["status"]}; setup completion is blocked because lockfile semantic diff is not trustworthy"
      ]
    end

    def setup_supply_chain_file_diff(before, after)
      setup_supply_chain_tracked_files.each_with_object([]) do |path, diff|
        before_entry = before[path] || { "present" => false }
        after_entry = after[path] || { "present" => false }
        next if before_entry == after_entry

        change =
          if !before_entry["present"] && after_entry["present"]
            "added"
          elsif before_entry["present"] && !after_entry["present"]
            "removed"
          else
            "changed"
          end
        diff << { "path" => path, "change" => change, "before" => before_entry, "after" => after_entry }
      end
    end


  end
end
