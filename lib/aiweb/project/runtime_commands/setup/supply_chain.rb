# frozen_string_literal: true

require_relative "supply_chain/broker"
require_relative "supply_chain/plan"
require_relative "supply_chain/network_policy"
require_relative "supply_chain/artifacts"

module Aiweb
  module ProjectRuntimeCommands
    private

    def setup_supply_chain_tracked_files
      %w[package.json pnpm-lock.yaml package-lock.json yarn.lock bun.lockb]
    end

    def setup_supply_chain_lockfile_paths
      %w[pnpm-lock.yaml package-lock.json yarn.lock bun.lockb]
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

    def setup_supply_chain_lockfile_snapshot
      path = File.join(root, "pnpm-lock.yaml")
      return setup_supply_chain_empty_lockfile_snapshot("missing") unless File.file?(path)

      data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
      unless data.is_a?(Hash)
        return setup_supply_chain_empty_lockfile_snapshot("invalid").merge(
          "error" => "pnpm-lock.yaml root is not a mapping"
        )
      end

      package_entries = setup_supply_chain_pnpm_lockfile_package_entries(data["packages"])
      network_refs = setup_supply_chain_collect_network_refs(data, "pnpm-lock.yaml")
      {
        "status" => "parsed",
        "path" => "pnpm-lock.yaml",
        "lockfile_version" => data["lockfileVersion"].to_s.empty? ? nil : data["lockfileVersion"].to_s,
        "importers" => setup_supply_chain_pnpm_lockfile_importers(data["importers"]),
        "package_entries" => package_entries,
        "package_versions" => setup_supply_chain_pnpm_lockfile_package_versions(package_entries),
        "network_refs" => network_refs,
        "network_allowlist_violations" => setup_supply_chain_network_allowlist_violations(network_refs)
      }
    rescue Psych::Exception => e
      setup_supply_chain_empty_lockfile_snapshot("invalid").merge("error" => e.message)
    rescue SystemCallError => e
      setup_supply_chain_empty_lockfile_snapshot("unreadable").merge("error" => e.message)
    end

    def setup_supply_chain_empty_lockfile_snapshot(status)
      {
        "status" => status,
        "path" => "pnpm-lock.yaml",
        "lockfile_version" => nil,
        "importers" => {},
        "package_entries" => [],
        "package_versions" => {},
        "network_refs" => [],
        "network_allowlist_violations" => []
      }
    end

    def setup_supply_chain_pnpm_lockfile_importers(raw_importers)
      return {} unless raw_importers.is_a?(Hash)

      raw_importers.keys.map(&:to_s).sort.to_h do |importer_name|
        importer = raw_importers[importer_name].is_a?(Hash) ? raw_importers[importer_name] : {}
        sections = setup_supply_chain_dependency_sections.to_h do |section|
          values = importer[section].is_a?(Hash) ? importer[section] : {}
          [
            section,
            values.keys.map(&:to_s).sort.to_h do |name|
              [name, setup_supply_chain_pnpm_lockfile_dependency_entry(values[name])]
            end
          ]
        end
        [importer_name, sections]
      end
    end

    def setup_supply_chain_pnpm_lockfile_dependency_entry(value)
      if value.is_a?(Hash)
        {
          "specifier" => value["specifier"].nil? ? nil : value["specifier"].to_s,
          "version" => value["version"].nil? ? nil : value["version"].to_s
        }.compact
      else
        { "version" => value.to_s }
      end
    end

    def setup_supply_chain_pnpm_lockfile_package_entries(raw_packages)
      return [] unless raw_packages.is_a?(Hash)

      raw_packages.keys.map(&:to_s).sort.map do |key|
        parsed = setup_supply_chain_parse_pnpm_package_key(key)
        {
          "key" => key,
          "name" => parsed.fetch("name"),
          "version" => parsed.fetch("version")
        }.compact
      end
    end

    def setup_supply_chain_parse_pnpm_package_key(key)
      normalized = key.to_s.sub(%r{\A/+}, "")
      split_at = normalized.start_with?("@") ? normalized.index("@", 1) : normalized.index("@")
      return { "name" => normalized, "version" => nil } unless split_at

      {
        "name" => normalized[0...split_at],
        "version" => normalized[(split_at + 1)..]
      }
    end

    def setup_supply_chain_pnpm_lockfile_package_versions(package_entries)
      package_entries
        .group_by { |entry| entry["name"] }
        .sort
        .to_h do |name, entries|
          versions = entries.map { |entry| entry["version"] }.compact.uniq.sort
          [name, versions]
        end
    end

    def setup_supply_chain_lockfile_semantic_diff(before, after)
      added_dependencies = []
      removed_dependencies = []
      specifier_changes = []
      version_changes = []
      importers = (before.fetch("importers", {}).keys + after.fetch("importers", {}).keys).uniq.sort
      importers.each do |importer|
        setup_supply_chain_dependency_sections.each do |section|
          before_values = before.dig("importers", importer, section).is_a?(Hash) ? before.dig("importers", importer, section) : {}
          after_values = after.dig("importers", importer, section).is_a?(Hash) ? after.dig("importers", importer, section) : {}
          (after_values.keys - before_values.keys).sort.each do |name|
            added_dependencies << setup_supply_chain_lockfile_dependency_change(importer, section, name, after_values[name])
          end
          (before_values.keys - after_values.keys).sort.each do |name|
            removed_dependencies << setup_supply_chain_lockfile_dependency_change(importer, section, name, before_values[name])
          end
          (before_values.keys & after_values.keys).sort.each do |name|
            before_entry = before_values[name] || {}
            after_entry = after_values[name] || {}
            if before_entry["specifier"] != after_entry["specifier"]
              specifier_changes << {
                "importer" => importer,
                "section" => section,
                "name" => name,
                "before" => before_entry["specifier"],
                "after" => after_entry["specifier"]
              }
            end
            next if before_entry["version"] == after_entry["version"]

            version_changes << {
              "importer" => importer,
              "section" => section,
              "name" => name,
              "before" => before_entry["version"],
              "after" => after_entry["version"]
            }
          end
        end
      end

      before_packages = Array(before["package_entries"])
      after_packages = Array(after["package_entries"])
      before_package_by_key = before_packages.to_h { |entry| [entry["key"], entry] }
      after_package_by_key = after_packages.to_h { |entry| [entry["key"], entry] }
      added_packages = (after_package_by_key.keys - before_package_by_key.keys).sort.map { |key| after_package_by_key[key] }
      removed_packages = (before_package_by_key.keys - after_package_by_key.keys).sort.map { |key| before_package_by_key[key] }
      package_version_changes = setup_supply_chain_lockfile_package_version_changes(
        before.fetch("package_versions", {}),
        after.fetch("package_versions", {})
      )
      lockfile_version_change = before["lockfile_version"] == after["lockfile_version"] ? nil : {
        "before" => before["lockfile_version"],
        "after" => after["lockfile_version"]
      }
      changed = before["status"] != after["status"] ||
        lockfile_version_change ||
        !(added_dependencies.empty? && removed_dependencies.empty? && specifier_changes.empty? && version_changes.empty? && added_packages.empty? && removed_packages.empty? && package_version_changes.empty?)

      {
        "status" => changed ? "changed" : "unchanged",
        "before_status" => before["status"],
        "after_status" => after["status"],
        "lockfile_version_change" => lockfile_version_change,
        "added_dependencies" => added_dependencies,
        "removed_dependencies" => removed_dependencies,
        "specifier_changes" => specifier_changes,
        "version_changes" => version_changes,
        "added_packages" => added_packages,
        "removed_packages" => removed_packages,
        "package_version_changes" => package_version_changes,
        "added_dependency_count" => added_dependencies.length,
        "removed_dependency_count" => removed_dependencies.length,
        "specifier_change_count" => specifier_changes.length,
        "version_change_count" => version_changes.length,
        "added_package_count" => added_packages.length,
        "removed_package_count" => removed_packages.length,
        "package_version_change_count" => package_version_changes.length
      }
    end

    def setup_supply_chain_lockfile_dependency_change(importer, section, name, entry)
      {
        "importer" => importer,
        "section" => section,
        "name" => name,
        "specifier" => entry["specifier"],
        "version" => entry["version"]
      }.compact
    end

    def setup_supply_chain_lockfile_package_version_changes(before_versions, after_versions)
      (before_versions.keys + after_versions.keys).uniq.sort.each_with_object([]) do |name, changes|
        before = Array(before_versions[name]).compact.uniq.sort
        after = Array(after_versions[name]).compact.uniq.sort
        next if before == after

        changes << {
          "name" => name,
          "before_versions" => before,
          "after_versions" => after,
          "added_versions" => (after - before),
          "removed_versions" => (before - after)
        }
      end
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
