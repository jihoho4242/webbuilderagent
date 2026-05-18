# frozen_string_literal: true

module Aiweb
  module ProjectRuntimeCommands
    private

    def setup_side_effect_broker_plan(command_argv:, broker_path:, dry_run:, approved:, blocked:, blockers:)
      side_effect_broker_plan(
        broker: "aiweb.setup.side_effect_broker",
        scope: "setup.package_install",
        target: "project_dependencies",
        command: command_argv,
        broker_path: broker_path,
        dry_run: dry_run,
        approved: approved,
        blocked: blocked,
        blockers: blockers,
        risk_class: "package_install_network_supply_chain",
        policy_extra: {
          "requires_exact_command" => true,
          "requires_approval" => true,
          "lifecycle_scripts_may_run" => false,
          "lifecycle_script_policy" => "disabled_by_default_with_ignore_scripts"
        }
      )
    end

    def setup_side_effect_broker_context(command_argv:, approved:, scope: "setup.package_install", target: "project_dependencies", network_call_status: "attempted_unknown_result")
      side_effect_broker_context(
        broker: "aiweb.setup.side_effect_broker",
        scope: scope,
        target: target,
        command: command_argv,
        risk_class: "package_install_network_supply_chain",
        approved: approved,
        extra: {
          "package_manager" => command_argv.first.to_s,
          "network_call_status" => network_call_status
        }
      )
    end

    def setup_run_brokered_supply_chain_command(broker_path, events, command_argv, scope:, target:, network_call_status:)
      started_at = now
      context = setup_side_effect_broker_context(
        command_argv: command_argv,
        approved: true,
        scope: scope,
        target: target,
        network_call_status: network_call_status
      )
      append_side_effect_broker_event(broker_path, events, "tool.requested", context.merge("requested_at" => started_at, "dry_run" => false))
      append_side_effect_broker_event(broker_path, events, "policy.decision", context.merge("decision" => "allow", "reason" => "explicit --approved setup supply-chain evidence"))
      append_side_effect_broker_event(broker_path, events, "tool.started", context.merge("started_at" => started_at))
      stdout, stderr, process_status = Open3.capture3(setup_child_env, *command_argv, chdir: root, unsetenv_others: true)
      status = process_status.success? ? "passed" : "failed"
      append_side_effect_broker_event(broker_path, events, "tool.finished", context.merge("finished_at" => now, "status" => status, "exit_code" => process_status.exitstatus))
      {
        "command" => command_argv,
        "status" => status,
        "exit_code" => process_status.exitstatus,
        "stdout" => redact_side_effect_process_output(redact_setup_output(stdout)),
        "stderr" => redact_side_effect_process_output(redact_setup_output(stderr))
      }
    end

    def setup_supply_chain_plan(package_manager:, command_argv:, package_cache_dir:, supply_chain_gate_path:, sbom_path:, cyclonedx_sbom_path:, spdx_sbom_path:, package_audit_path:, audit_exception:, status:, blocking_issues:, lifecycle_scripts:, lifecycle_enabled_requested: false)
      {
        "schema_version" => 1,
        "status" => status,
        "recorded_at" => now,
        "package_manager" => package_manager,
        "exact_command" => redact_side_effect_command(command_argv),
        "clean_cache_install" => {
          "status" => status == "planned" ? "planned" : status,
          "isolated_cache_dir" => relative(package_cache_dir),
          "registry_allowlist" => [setup_supply_chain_registry_url],
          "network_allowlist" => [setup_supply_chain_registry_host],
          "network_policy" => "package.json direct network specs and pnpm-lock.yaml network refs must resolve only to the approved registry host",
          "command_policy" => "exact command must include --ignore-scripts, approved registry, and run-local --store-dir",
          "lifecycle_script_policy" => "disabled_by_default_with_ignore_scripts",
          "default_install_lifecycle_execution" => false,
          "default_command_uses_ignore_scripts" => setup_command_uses_ignore_scripts?(command_argv)
        },
        "dependency_diff" => {
          "status" => status == "planned" ? "planned" : status,
          "tracked_files" => setup_supply_chain_tracked_files,
          "semantic_sections" => setup_supply_chain_dependency_sections,
          "required_outputs" => %w[package_file_diff semantic_dependency_diff lockfile_diff lockfile_semantic_diff network_allowlist_enforcement added_packages removed_packages version_changes]
        },
        "sbom" => {
          "status" => status == "planned" ? "planned" : status,
          "artifact_path" => relative(sbom_path),
          "standard_artifact_path" => relative(cyclonedx_sbom_path),
          "spdx_artifact_path" => relative(spdx_sbom_path),
          "accepted_formats" => ["CycloneDX 1.5 JSON", "SPDX 2.3 JSON"],
          "command" => setup_supply_chain_sbom_argv(package_manager)
        },
        "audit" => {
          "status" => status == "planned" ? "planned" : status,
          "artifact_path" => relative(package_audit_path),
          "command" => setup_supply_chain_audit_argv(package_manager)
        },
        "vulnerability_copy_back_gate" => {
          "status" => status == "blocked" ? "blocked" : "planned",
          "blocked_severities" => %w[critical high],
          "audit_exception" => audit_exception
        },
        "network_allowlist_enforcement" => setup_supply_chain_network_allowlist_evidence(
          dependency_snapshot: nil,
          dependency_semantic_before: setup_supply_chain_dependency_snapshot,
          dependency_semantic_after: nil,
          lockfile_semantic_before: setup_supply_chain_lockfile_snapshot,
          lockfile_semantic_after: nil
        ),
        "lifecycle_sandbox_gate" => setup_lifecycle_sandbox_gate(
          command_argv: command_argv,
          package_cache_dir: package_cache_dir,
          lifecycle_scripts: lifecycle_scripts,
          install_status: status,
          execution_evidence_status: status == "planned" ? "planned" : "not_executed",
          lifecycle_enabled_requested: lifecycle_enabled_requested
        ),
        "evidence_refs" => {
          "supply_chain_gate_path" => relative(supply_chain_gate_path),
          "sbom_path" => relative(sbom_path),
          "cyclonedx_sbom_path" => relative(cyclonedx_sbom_path),
          "spdx_sbom_path" => relative(spdx_sbom_path),
          "package_audit_path" => relative(package_audit_path)
        },
        "blocking_issues" => blocking_issues
      }
    end

    def setup_supply_chain_gate(package_manager:, command_argv:, package_cache_dir:, supply_chain_gate_path:, sbom_path:, cyclonedx_sbom_path:, spdx_sbom_path:, package_audit_path:, audit_exception:, install_status:, install_exit_code:, dependency_snapshot_before:, dependency_snapshot_after:, dependency_semantic_before:, dependency_semantic_after:, lockfile_semantic_before:, lockfile_semantic_after:, sbom_artifact:, cyclonedx_sbom_artifact:, spdx_sbom_artifact:, audit_artifact:, blocking_issues:, lifecycle_scripts:, lifecycle_enabled_requested: false)
      file_diff = setup_supply_chain_file_diff(dependency_snapshot_before, dependency_snapshot_after)
      semantic_diff = setup_supply_chain_dependency_semantic_diff(dependency_semantic_before, dependency_semantic_after)
      lockfile_semantic_diff = setup_supply_chain_lockfile_semantic_diff(lockfile_semantic_before, lockfile_semantic_after)
      lockfile_diff = file_diff.select { |entry| entry.fetch("path", "").end_with?("-lock.yaml", "-lock.json", ".lock", "lockfile") || setup_supply_chain_lockfile_paths.include?(entry.fetch("path", "")) }
      cyclonedx_status = setup_supply_chain_cyclonedx_status(cyclonedx_sbom_artifact)
      spdx_status = setup_supply_chain_spdx_status(spdx_sbom_artifact)
      {
        "schema_version" => 1,
        "status" => blocking_issues.empty? && install_status == "passed" ? "passed" : "blocked",
        "recorded_at" => now,
        "package_manager" => package_manager,
        "exact_command" => redact_side_effect_command(command_argv),
        "install_status" => install_status,
        "install_exit_code" => install_exit_code,
        "clean_cache_install" => {
          "status" => install_status == "passed" ? "executed" : install_status,
          "isolated_cache_dir" => relative(package_cache_dir),
          "cache_dir_present" => File.directory?(package_cache_dir),
          "registry_allowlist" => [setup_supply_chain_registry_url],
          "network_allowlist" => [setup_supply_chain_registry_host],
          "network_policy" => "package.json direct network specs and pnpm-lock.yaml network refs must resolve only to the approved registry host",
          "command_policy" => "exact pnpm install command includes --ignore-scripts, approved registry, and run-local --store-dir",
          "lifecycle_script_policy" => "disabled_by_default_with_ignore_scripts; future lifecycle-enabled installs require sandboxed elevated approval",
          "default_install_lifecycle_execution" => false,
          "default_command_uses_ignore_scripts" => setup_command_uses_ignore_scripts?(command_argv)
        },
        "dependency_diff" => {
          "status" => file_diff.empty? && semantic_diff["status"] == "unchanged" && lockfile_semantic_diff["status"] == "unchanged" ? "unchanged" : "changed",
          "before" => dependency_snapshot_before,
          "after" => dependency_snapshot_after,
          "semantic_before" => dependency_semantic_before,
          "semantic_after" => dependency_semantic_after,
          "semantic_dependency_diff" => semantic_diff,
          "lockfile_semantic_before" => lockfile_semantic_before,
          "lockfile_semantic_after" => lockfile_semantic_after,
          "lockfile_semantic_diff" => lockfile_semantic_diff,
          "lockfile_diff" => lockfile_diff,
          "package_file_diff" => file_diff,
          "required_outputs" => %w[package_file_diff semantic_dependency_diff lockfile_diff lockfile_semantic_diff network_allowlist_enforcement added_packages removed_packages version_changes]
        },
        "sbom" => {
          "status" => sbom_artifact["status"],
          "artifact_path" => relative(sbom_path),
          "standard_status" => cyclonedx_status,
          "standard_format" => "CycloneDX 1.5 JSON",
          "standard_artifact_path" => relative(cyclonedx_sbom_path),
          "spdx_status" => spdx_status,
          "spdx_format" => "SPDX 2.3 JSON",
          "spdx_artifact_path" => relative(spdx_sbom_path),
          "component_count" => sbom_artifact["component_count"].to_i,
          "command" => sbom_artifact["command"]
        },
        "audit" => {
          "status" => audit_artifact["status"],
          "artifact_path" => relative(package_audit_path),
          "severity_counts" => audit_artifact["severity_counts"] || {},
          "active_findings" => audit_artifact["active_findings"] || [],
          "audit_artifact_sha256" => audit_artifact["audit_artifact_sha256"],
          "audit_exception" => audit_exception,
          "command" => audit_artifact["command"]
        },
        "vulnerability_copy_back_gate" => {
          "status" => audit_exception["status"] == "accepted" ? "accepted_risk" : (audit_artifact["vulnerability_gate"] || "not_executed"),
          "blocked_severities" => %w[critical high],
          "policy" => "block setup completion on critical/high vulnerabilities unless an approved, unexpired audit exception with rollback plan is supplied",
          "audit_exception" => audit_exception
        },
        "network_allowlist_enforcement" => setup_supply_chain_network_allowlist_evidence(
          dependency_snapshot: dependency_snapshot_after,
          dependency_semantic_before: dependency_semantic_before,
          dependency_semantic_after: dependency_semantic_after,
          lockfile_semantic_before: lockfile_semantic_before,
          lockfile_semantic_after: lockfile_semantic_after
        ),
        "lifecycle_sandbox_gate" => setup_lifecycle_sandbox_gate(
          command_argv: command_argv,
          package_cache_dir: package_cache_dir,
          lifecycle_scripts: lifecycle_scripts,
          install_status: install_status,
          execution_evidence_status: blocking_issues.empty? && install_status == "passed" ? "default_install_executed_without_lifecycle_scripts" : "blocked",
          lifecycle_enabled_requested: lifecycle_enabled_requested
        ),
        "execution_evidence" => {
          "status" => blocking_issues.empty? && install_status == "passed" ? "executed" : "blocked",
          "artifacts" => [relative(sbom_path), relative(cyclonedx_sbom_path), relative(spdx_sbom_path), relative(package_audit_path)]
        },
        "evidence_refs" => {
          "supply_chain_gate_path" => relative(supply_chain_gate_path),
          "sbom_path" => relative(sbom_path),
          "cyclonedx_sbom_path" => relative(cyclonedx_sbom_path),
          "spdx_sbom_path" => relative(spdx_sbom_path),
          "package_audit_path" => relative(package_audit_path)
        },
        "blocking_issues" => blocking_issues
      }
    end

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

    def setup_supply_chain_dependency_network_refs(sections)
      sections.flat_map do |section, values|
        values.to_h.flat_map do |name, specifier|
          refs = setup_supply_chain_extract_network_refs(
            specifier.to_s,
            path: "package.json/#{section}/#{name}",
            source: "package.json"
          )
          if refs.empty? && setup_supply_chain_dependency_spec_remote_like?(specifier.to_s)
            refs << setup_supply_chain_remote_dependency_spec_ref(
              specifier.to_s,
              path: "package.json/#{section}/#{name}",
              source: "package.json"
            )
          end
          refs
        end
      end
    end

    def setup_supply_chain_redact_dependency_specifier(value)
      setup_supply_chain_extract_network_refs(value, path: "package.json", source: "package.json").empty? ? value.to_s : setup_supply_chain_redact_network_ref(value)
    end

    def setup_supply_chain_collect_network_refs(value, path, refs = [])
      case value
      when Hash
        value.each do |key, item|
          setup_supply_chain_collect_network_refs(item, "#{path}/#{key}", refs)
        end
      when Array
        value.each_with_index do |item, index|
          setup_supply_chain_collect_network_refs(item, "#{path}/#{index}", refs)
        end
      when String
        refs.concat(setup_supply_chain_extract_network_refs(value, path: path, source: "pnpm-lock.yaml"))
      end
      refs.uniq { |ref| [ref["source"], ref["path"], ref["value"]] }
    end

    def setup_supply_chain_extract_network_refs(value, path:, source:)
      value.to_s.scan(%r{(?:git\+)?(?:https?|git|ssh)://[^\s"'<>]+|git@[A-Za-z0-9_.-]+:[^\s"'<>]+|(?:github|gitlab|bitbucket|gist):[A-Za-z0-9_.-]+/[^\s"'<>]+}i).map do |ref|
        host = setup_supply_chain_network_ref_host(ref)
        scheme = setup_supply_chain_network_ref_scheme(ref)
        {
          "source" => source,
          "path" => path,
          "value" => setup_supply_chain_redact_network_ref(ref),
          "scheme" => scheme,
          "host" => host,
          "allowed" => setup_supply_chain_network_ref_allowed?(scheme, host)
        }
      end
    end

    def setup_supply_chain_redact_network_ref(value)
      value.to_s
        .sub(%r{\A((?:git\+)?[a-z][a-z0-9+.-]*://)[^/@\s]+@}i, "\\1redacted@")
        .gsub(/([?&][^=&\s]*(?:token|auth|secret|key|credential|password|signature)[^=&\s]*=)[^&\s]+/i, "\\1[redacted]")
    end

    def setup_supply_chain_dependency_spec_remote_like?(value)
      text = value.to_s.strip
      return false if text.empty? || setup_supply_chain_dependency_spec_local_or_registry?(text)

      text.match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:[#?].*)?\z}) ||
        text.match?(/\.git(?:[#?]|\z)/i) ||
        text.match?(/\A[A-Za-z][A-Za-z0-9+.-]*:/)
    end

    def setup_supply_chain_dependency_spec_local_or_registry?(value)
      text = value.to_s.strip
      return true if text.match?(/\A(?:latest|next|beta|alpha|canary|stable)\z/i)
      return true if text.match?(/\A[~^<>=*xXv0-9.,\s|_-]+\z/)
      return true if text.match?(/\A(?:workspace|file|link|portal|patch|catalog|npm):/i)

      false
    end

    def setup_supply_chain_remote_dependency_spec_ref(value, path:, source:)
      host = setup_supply_chain_remote_dependency_spec_host(value)
      scheme = setup_supply_chain_remote_dependency_spec_scheme(value)
      {
        "source" => source,
        "path" => path,
        "value" => setup_supply_chain_redact_network_ref(value),
        "scheme" => scheme,
        "host" => host,
        "allowed" => false
      }
    end

    def setup_supply_chain_remote_dependency_spec_host(value)
      text = value.to_s.strip
      return "github.com" if text.match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:[#?].*)?\z})

      setup_supply_chain_network_ref_host(text) || "unknown-remote"
    end

    def setup_supply_chain_remote_dependency_spec_scheme(value)
      text = value.to_s.strip
      return "github-shorthand" if text.match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:[#?].*)?\z})

      setup_supply_chain_network_ref_scheme(text) || "remote-spec"
    end

    def setup_supply_chain_network_ref_host(value)
      text = value.to_s
      return "github.com" if text.start_with?("github:")
      return "gitlab.com" if text.start_with?("gitlab:")
      return "bitbucket.org" if text.start_with?("bitbucket:")
      return "gist.github.com" if text.start_with?("gist:")
      return Regexp.last_match(1).downcase if text.match(/\Agit@([^:]+):/i)

      URI.parse(text.sub(/\Agit\+/, "")).host.to_s.downcase
    rescue URI::InvalidURIError
      nil
    end

    def setup_supply_chain_network_ref_scheme(value)
      text = value.to_s
      return "github" if text.start_with?("github:")
      return "gitlab" if text.start_with?("gitlab:")
      return "bitbucket" if text.start_with?("bitbucket:")
      return "gist" if text.start_with?("gist:")
      return "ssh" if text.match?(/\Agit@[^:]+:/i)

      URI.parse(text.sub(/\Agit\+/, "")).scheme.to_s.downcase
    rescue URI::InvalidURIError
      nil
    end

    def setup_supply_chain_network_ref_allowed?(scheme, host)
      scheme.to_s == "https" && host.to_s == setup_supply_chain_registry_host
    end

    def setup_supply_chain_network_allowlist_violations(refs)
      Array(refs).reject { |ref| ref["allowed"] == true }
    end

    def setup_supply_chain_network_allowlist_blockers(dependency_snapshot, lockfile_snapshot, phase:)
      violations = setup_supply_chain_network_allowlist_violations(Array(dependency_snapshot["network_refs"]) + Array(lockfile_snapshot["network_refs"]))
      return [] if violations.empty?

      sample = violations.first(5).map do |ref|
        "#{ref["source"]}:#{ref["path"]} -> #{ref["host"] || "unknown-host"}"
      end
      [
        "#{phase} setup network allowlist blocked dependency references outside #{setup_supply_chain_registry_host}: #{sample.join(", ")}"
      ]
    end

    def setup_supply_chain_network_allowlist_evidence(dependency_snapshot:, dependency_semantic_before:, dependency_semantic_after:, lockfile_semantic_before:, lockfile_semantic_after:)
      before_refs = Array(dependency_semantic_before&.fetch("network_refs", nil)) + Array(lockfile_semantic_before&.fetch("network_refs", nil))
      after_refs = Array(dependency_semantic_after&.fetch("network_refs", nil)) + Array(lockfile_semantic_after&.fetch("network_refs", nil))
      before_violations = setup_supply_chain_network_allowlist_violations(before_refs)
      after_violations = setup_supply_chain_network_allowlist_violations(after_refs)
      {
        "status" => before_violations.empty? && after_violations.empty? ? "passed" : "blocked",
        "policy" => "package.json and pnpm-lock.yaml network references must use HTTPS and host #{setup_supply_chain_registry_host}; direct git, ssh, GitHub shortcut, or non-allowlisted tarball URLs block setup completion",
        "allowlist_hosts" => [setup_supply_chain_registry_host],
        "registry_allowlist" => [setup_supply_chain_registry_url],
        "package_file_sha256" => dependency_snapshot&.dig("package.json", "sha256"),
        "before_ref_count" => before_refs.length,
        "after_ref_count" => after_refs.length,
        "before_violations" => before_violations,
        "after_violations" => after_violations
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

    def setup_supply_chain_not_executed_artifact(kind:, status:, package_manager:, command_argv:, reason:)
      {
        "schema_version" => 1,
        "artifact_kind" => kind,
        "status" => status,
        "recorded_at" => now,
        "package_manager" => package_manager,
        "command" => command_argv,
        "reason" => reason
      }
    end

    def setup_supply_chain_sbom_artifact(package_manager:, command_result:, dependency_snapshot:)
      parsed = setup_parse_json(command_result["stdout"])
      components = setup_supply_chain_components(parsed)
      status = command_result["status"] == "passed" && parsed ? "generated" : "failed"
      {
        "schema_version" => 1,
        "artifact_kind" => "sbom",
        "status" => status,
        "recorded_at" => now,
        "package_manager" => package_manager,
        "format" => "aiweb-pnpm-list-sbom-v1",
        "command" => command_result["command"],
        "exit_code" => command_result["exit_code"],
        "component_count" => components.length,
        "components" => components,
        "dependency_files" => dependency_snapshot,
        "stderr" => command_result["stderr"],
        "raw" => parsed
      }
    end

    def setup_supply_chain_cyclonedx_sbom_artifact(package_manager:, sbom_artifact:)
      unless sbom_artifact["status"] == "generated"
        return setup_supply_chain_not_executed_artifact(
          kind: "cyclonedx_sbom",
          status: "failed",
          package_manager: package_manager,
          command_argv: setup_supply_chain_sbom_argv(package_manager),
          reason: "source dependency inventory SBOM was not generated"
        )
      end

      {
        "$schema" => "https://cyclonedx.org/schema/bom-1.5.schema.json",
        "bomFormat" => "CycloneDX",
        "specVersion" => "1.5",
        "serialNumber" => "urn:uuid:#{SecureRandom.uuid}",
        "version" => 1,
        "metadata" => {
          "timestamp" => now,
          "tools" => {
            "components" => [
              {
                "type" => "application",
                "name" => "aiweb",
                "version" => defined?(Aiweb::VERSION) ? Aiweb::VERSION : "unknown"
              }
            ]
          }
        },
        "components" => setup_supply_chain_cyclonedx_components(sbom_artifact["components"])
      }
    end

    def setup_supply_chain_cyclonedx_status(cyclonedx_sbom_artifact)
      if cyclonedx_sbom_artifact["bomFormat"] == "CycloneDX" &&
          cyclonedx_sbom_artifact["specVersion"] == "1.5" &&
          cyclonedx_sbom_artifact["components"].is_a?(Array)
        "generated"
      else
        cyclonedx_sbom_artifact["status"].to_s
      end
    end

    def setup_supply_chain_cyclonedx_components(components)
      Array(components).filter_map do |component|
        name = component["name"].to_s
        version = component["version"].to_s
        next if name.empty? || version.empty?

        {
          "type" => "library",
          "name" => name,
          "version" => version
        }
      end
    end

    def setup_supply_chain_spdx_sbom_artifact(package_manager:, sbom_artifact:)
      unless sbom_artifact["status"] == "generated"
        return setup_supply_chain_not_executed_artifact(
          kind: "spdx_sbom",
          status: "failed",
          package_manager: package_manager,
          command_argv: setup_supply_chain_sbom_argv(package_manager),
          reason: "source dependency inventory SBOM was not generated"
        )
      end

      timestamp = now
      {
        "spdxVersion" => "SPDX-2.3",
        "dataLicense" => "CC0-1.0",
        "SPDXID" => "SPDXRef-DOCUMENT",
        "name" => "aiweb-setup-#{package_manager}-dependencies",
        "documentNamespace" => "https://aiweb.local/spdx/#{SecureRandom.uuid}",
        "creationInfo" => {
          "created" => timestamp,
          "creators" => ["Tool: aiweb-#{defined?(Aiweb::VERSION) ? Aiweb::VERSION : "unknown"}"]
        },
        "packages" => setup_supply_chain_spdx_packages(sbom_artifact["components"])
      }
    end

    def setup_supply_chain_spdx_status(spdx_sbom_artifact)
      if spdx_sbom_artifact["spdxVersion"] == "SPDX-2.3" &&
          spdx_sbom_artifact["dataLicense"] == "CC0-1.0" &&
          spdx_sbom_artifact["SPDXID"] == "SPDXRef-DOCUMENT" &&
          !spdx_sbom_artifact["name"].to_s.empty? &&
          spdx_sbom_artifact["documentNamespace"].to_s.start_with?("https://aiweb.local/spdx/") &&
          spdx_sbom_artifact.dig("creationInfo", "created").to_s.match?(/\A\d{4}-\d{2}-\d{2}T/) &&
          Array(spdx_sbom_artifact.dig("creationInfo", "creators")).any? { |creator| creator.to_s.start_with?("Tool: aiweb-") } &&
          spdx_sbom_artifact["packages"].is_a?(Array)
        "generated"
      else
        spdx_sbom_artifact["status"].to_s
      end
    end

    def setup_supply_chain_spdx_packages(components)
      Array(components).each_with_index.filter_map do |component, index|
        name = component["name"].to_s
        version = component["version"].to_s
        next if name.empty? || version.empty?

        {
          "name" => name,
          "SPDXID" => "SPDXRef-Package-#{index + 1}",
          "versionInfo" => version,
          "downloadLocation" => "NOASSERTION",
          "filesAnalyzed" => false,
          "licenseConcluded" => "NOASSERTION",
          "licenseDeclared" => "NOASSERTION",
          "copyrightText" => "NOASSERTION"
        }
      end
    end

    def setup_audit_exception_plan(audit_exception_path)
      path_info = setup_audit_exception_path_info(audit_exception_path)
      {
        "schema_version" => 1,
        "status" => path_info["status"] == "provided" ? "planned" : path_info["status"],
        "required" => false,
        "path" => path_info["path"],
        "policy" => "critical/high audit findings require an approved unexpired exception with rollback plan",
        "blocking_issues" => path_info["blocking_issues"]
      }.compact
    end

    def setup_audit_exception_evidence(audit_exception_path, audit_artifact:, package_manager:)
      active_severities = setup_audit_exception_active_severities(audit_artifact)
      path_info = setup_audit_exception_path_info(audit_exception_path)
      base = {
        "schema_version" => 1,
        "status" => path_info["status"],
        "required" => active_severities.any?,
        "path" => path_info["path"],
        "active_blocked_severities" => active_severities,
        "policy" => "critical/high audit findings require an approved unexpired exception with rollback plan",
        "blocking_issues" => Array(path_info["blocking_issues"])
      }
      if path_info["status"] == "not_requested"
        base["blocking_issues"] << "setup audit exception was not supplied for critical/high vulnerability findings" if active_severities.any?
        return base
      end
      return base.merge("status" => "invalid") unless base.fetch("blocking_issues").empty?

      unless File.file?(path_info.fetch("full_path"))
        base["blocking_issues"] << "setup audit exception file is missing: #{path_info["path"]}"
        return base.merge("status" => "invalid")
      end

      real_path = File.realpath(path_info.fetch("full_path"))
      real_relative = relative(real_path).tr("\\", "/")
      unless real_relative.start_with?(".ai-web/approvals/") && !unsafe_env_path?(real_relative) && !secret_looking_path?(real_relative)
        base["blocking_issues"] << "setup audit exception resolved path must stay inside .ai-web/approvals"
        return base.merge("status" => "invalid")
      end

      raw = File.read(real_path)
      if redact_side_effect_process_output(raw) != raw
        base["blocking_issues"] << "setup audit exception contains secret-looking content"
        return base.merge("status" => "invalid")
      end

      data = JSON.parse(raw)
      unless data.is_a?(Hash)
        base["blocking_issues"] << "setup audit exception root must be a JSON object"
        return base.merge("status" => "invalid")
      end

      blockers = setup_audit_exception_blockers(data, active_severities, package_manager, audit_artifact)
      evidence = base.merge(
        "status" => blockers.empty? ? "accepted" : "invalid",
        "approved" => data["approved"] == true,
        "accepted_risk" => data["accepted_risk"] == true,
        "approval_kind" => data["approval_kind"],
        "approved_by" => data["approved_by"].to_s,
        "approved_at" => data["approved_at"].to_s,
        "expires_at" => data["expires_at"].to_s,
        "reason" => data["reason"].to_s,
        "accepted_severities" => setup_audit_exception_declared_severities(data),
        "active_findings" => setup_audit_blocking_findings(audit_artifact),
        "audit_artifact_sha256" => setup_audit_artifact_sha256(audit_artifact),
        "accepted_findings" => setup_audit_exception_declared_findings(data),
        "rollback_plan" => setup_audit_exception_rollback_evidence(data["rollback_plan"])
      )
      evidence["blocking_issues"] = blockers
      evidence
    rescue JSON::ParserError => e
      base.merge("status" => "invalid", "blocking_issues" => base.fetch("blocking_issues") + ["setup audit exception JSON is invalid: #{e.message}"])
    rescue SystemCallError => e
      base.merge("status" => "invalid", "blocking_issues" => base.fetch("blocking_issues") + ["setup audit exception could not be read: #{e.message}"])
    end

    def setup_audit_exception_path_info(audit_exception_path)
      raw_path = audit_exception_path.to_s.strip
      return { "status" => "not_requested", "path" => nil, "blocking_issues" => [] } if raw_path.empty?

      full_path = File.expand_path(raw_path, root)
      root_path = File.expand_path(root)
      relative_path = full_path.start_with?(root_path + File::SEPARATOR) ? relative(full_path).tr("\\", "/") : raw_path.tr("\\", "/")
      blockers = []
      blockers << "setup audit exception path must stay inside the project" unless full_path.start_with?(root_path + File::SEPARATOR)
      blockers << "setup audit exception path must be under .ai-web/approvals" unless relative_path.start_with?(".ai-web/approvals/")
      blockers << "setup audit exception path must not target .env files" if unsafe_env_path?(relative_path)
      blockers << "setup audit exception path must not be secret-looking" if secret_looking_path?(relative_path)
      {
        "status" => blockers.empty? ? "provided" : "invalid",
        "path" => relative_path,
        "full_path" => full_path,
        "blocking_issues" => blockers
      }
    end

    def setup_audit_exception_active_severities(audit_artifact)
      counts = audit_artifact["severity_counts"].is_a?(Hash) ? audit_artifact["severity_counts"] : {}
      %w[critical high].select { |severity| counts[severity].to_i.positive? }
    end

    def setup_audit_exception_blockers(data, active_severities, package_manager, audit_artifact)
      blockers = []
      blockers << "setup audit exception schema_version must be 1" unless data["schema_version"] == 1
      blockers << "setup audit exception approval_kind must be setup_audit_exception" unless data["approval_kind"] == "setup_audit_exception"
      blockers << "setup audit exception must set approved: true" unless data["approved"] == true
      blockers << "setup audit exception must set accepted_risk: true" unless data["accepted_risk"] == true
      blockers << "setup audit exception approved_by is required" if data["approved_by"].to_s.strip.empty?
      blockers << "setup audit exception reason is required" if data["reason"].to_s.strip.empty?
      blockers.concat(setup_audit_exception_time_blockers(data["approved_at"], data["expires_at"]))
      declared_severities = setup_audit_exception_declared_severities(data)
      missing_severities = active_severities - declared_severities
      blockers << "setup audit exception does not cover active blocked severities: #{missing_severities.join(", ")}" unless missing_severities.empty?
      applies_package_manager = data.dig("applies_to", "package_manager").to_s
      blockers << "setup audit exception package_manager does not match #{package_manager}" unless applies_package_manager == package_manager
      finding_blockers = setup_audit_exception_finding_blockers(data, audit_artifact)
      blockers.concat(finding_blockers)
      rollback_blockers = setup_audit_exception_rollback_blockers(data["rollback_plan"])
      blockers.concat(rollback_blockers)
      blockers
    end

    def setup_audit_exception_declared_severities(data)
      Array(data.dig("applies_to", "blocked_severities") || data["blocked_severities"]).map(&:to_s).select { |severity| %w[critical high].include?(severity) }.uniq
    end

    def setup_audit_exception_time_blockers(approved_at, expires_at)
      blockers = []
      approved_time = nil
      expires_time = nil
      begin
        approved_time = Time.iso8601(approved_at.to_s)
        blockers << "setup audit exception approved_at must not be in the future" if approved_time > Time.now.utc
      rescue ArgumentError
        blockers << "setup audit exception approved_at must be ISO-8601"
      end
      begin
        expires_time = Time.iso8601(expires_at.to_s)
        blockers << "setup audit exception expires_at must be in the future" unless expires_time > Time.now.utc
      rescue ArgumentError
        blockers << "setup audit exception expires_at must be ISO-8601"
      end
      if approved_time && expires_time
        blockers << "setup audit exception expires_at must be after approved_at" unless expires_time > approved_time
      end
      blockers
    end

    def setup_audit_exception_finding_blockers(data, audit_artifact)
      expected_hash = setup_audit_artifact_sha256(audit_artifact)
      declared_hash = data.dig("applies_to", "audit_artifact_sha256").to_s
      return [] if !declared_hash.empty? && declared_hash == expected_hash

      blockers = []
      blockers << "setup audit exception audit_artifact_sha256 does not match active audit artifact" unless declared_hash.empty?
      active_findings = setup_audit_blocking_findings(audit_artifact)
      if active_findings.empty?
        blockers << "setup audit exception must bind to active audit artifact hash when detailed findings are unavailable"
        return blockers
      end

      declared_findings = setup_audit_exception_declared_findings(data)
      missing = active_findings.reject do |finding|
        declared_findings.any? { |declared| setup_audit_exception_finding_matches?(declared, finding) }
      end
      unless missing.empty?
        blockers << "setup audit exception does not cover active findings: #{missing.map { |finding| setup_audit_finding_label(finding) }.join(", ")}"
      end
      blockers
    end

    def setup_audit_exception_declared_findings(data)
      Array(data.dig("applies_to", "findings") || data["findings"]).filter_map do |finding|
        next unless finding.is_a?(Hash)

        {
          "package_name" => finding["package_name"].to_s.empty? ? finding["package"].to_s : finding["package_name"].to_s,
          "severity" => finding["severity"].to_s.downcase,
          "advisory_id" => finding["advisory_id"].to_s.empty? ? finding["id"].to_s : finding["advisory_id"].to_s
        }.reject { |_, value| value.to_s.empty? }
      end
    end

    def setup_audit_exception_finding_matches?(declared, active)
      return false unless declared["package_name"] == active["package_name"]
      return false unless declared["severity"] == active["severity"]

      active_advisory = active["advisory_id"].to_s
      active_advisory.empty? || declared["advisory_id"].to_s == active_advisory
    end

    def setup_audit_artifact_sha256(audit_artifact)
      Digest::SHA256.hexdigest(JSON.generate(audit_artifact["raw"] || {}))
    end

    def setup_audit_blocking_findings(audit_artifact)
      setup_audit_findings(audit_artifact["raw"]).select { |finding| %w[critical high].include?(finding["severity"]) }
    end

    def setup_audit_findings(raw)
      return [] unless raw.is_a?(Hash)

      findings = []
      vulnerabilities = raw["vulnerabilities"]
      if vulnerabilities.is_a?(Hash)
        vulnerabilities.each do |key, value|
          next unless value.is_a?(Hash)

          finding = setup_audit_finding_from_hash(value, fallback_name: key)
          findings << finding if finding
        end
      end
      advisories = raw["advisories"]
      if advisories.is_a?(Hash)
        advisories.each do |key, value|
          next unless value.is_a?(Hash)

          finding = setup_audit_finding_from_hash(value, fallback_advisory: key)
          findings << finding if finding
        end
      end
      findings.uniq
    end

    def setup_audit_finding_from_hash(value, fallback_name: nil, fallback_advisory: nil)
      severity = value["severity"].to_s.downcase
      return nil unless %w[critical high moderate low].include?(severity)

      name = value["name"] || value["packageName"] || value["module_name"] || value["moduleName"] || fallback_name
      advisory = value["id"] || value["advisory_id"] || value["advisoryId"] || value["source"] || value["url"] || fallback_advisory
      {
        "package_name" => name.to_s,
        "severity" => severity,
        "advisory_id" => advisory.to_s,
        "current_version" => (value["version"] || value["current"] || value["installedVersion"]).to_s
      }.reject { |_, child| child.to_s.empty? }
    end

    def setup_audit_finding_label(finding)
      [
        finding["package_name"],
        finding["severity"],
        finding["advisory_id"]
      ].compact.join("@")
    end

    def setup_audit_exception_rollback_blockers(rollback_plan)
      return ["setup audit exception rollback_plan must be an object"] unless rollback_plan.is_a?(Hash)

      blockers = []
      blockers << "setup audit exception rollback_plan.summary is required" if rollback_plan["summary"].to_s.strip.empty?
      steps = Array(rollback_plan["steps"])
      blockers << "setup audit exception rollback_plan.steps must include at least one step" if steps.empty? || steps.all? { |step| step.to_s.strip.empty? }
      blockers
    end

    def setup_audit_exception_rollback_evidence(rollback_plan)
      return nil unless rollback_plan.is_a?(Hash)

      {
        "summary" => redact_side_effect_process_output(rollback_plan["summary"].to_s),
        "steps" => Array(rollback_plan["steps"]).map { |step| redact_side_effect_process_output(step.to_s) }.reject(&:empty?)
      }
    end

    def setup_supply_chain_audit_artifact(package_manager:, command_result:)
      parsed = setup_parse_json(command_result["stdout"])
      severity_counts = setup_audit_severity_counts(parsed)
      critical_high = severity_counts.fetch("critical", 0).to_i + severity_counts.fetch("high", 0).to_i
      parsed_ok = !parsed.nil?
      recognized_audit_payload = setup_audit_payload?(parsed)
      command_failed = command_result["status"] != "passed"
      status =
        if !parsed_ok || (command_failed && !recognized_audit_payload)
          "failed"
        elsif critical_high.positive?
          "blocked"
        else
          "passed"
        end
      {
        "schema_version" => 1,
        "artifact_kind" => "package_audit",
        "status" => status,
        "recorded_at" => now,
        "package_manager" => package_manager,
        "command" => command_result["command"],
        "exit_code" => command_result["exit_code"],
        "severity_counts" => severity_counts,
        "active_findings" => setup_audit_blocking_findings("raw" => parsed),
        "audit_artifact_sha256" => Digest::SHA256.hexdigest(JSON.generate(parsed || {})),
        "vulnerability_gate" => critical_high.positive? ? "blocked" : (status == "failed" ? "failed" : "passed"),
        "blocked_severities" => %w[critical high],
        "stderr" => command_result["stderr"],
        "raw" => parsed
      }
    end

    def setup_audit_payload?(value)
      return false unless value.is_a?(Hash)

      value.dig("metadata", "vulnerabilities").is_a?(Hash) ||
        value["vulnerabilities"].is_a?(Hash) ||
        value["advisories"].is_a?(Hash) ||
        value.key?("auditReportVersion")
    end

    def setup_parse_json(text)
      JSON.parse(text.to_s)
    rescue JSON::ParserError
      nil
    end

    def setup_supply_chain_components(value, components = [], seen = {})
      case value
      when Array
        value.each { |item| setup_supply_chain_components(item, components, seen) }
      when Hash
        name = value["name"] || value["packageName"]
        version = value["version"]
        key = [name, version].join("@")
        if name && version && !seen[key]
          seen[key] = true
          components << {
            "name" => name,
            "version" => version,
            "path" => value["path"],
            "private" => value["private"] == true
          }.compact
        end
        dependencies = value["dependencies"]
        if dependencies.is_a?(Hash)
          dependencies.each_value { |dependency| setup_supply_chain_components(dependency, components, seen) }
        elsif dependencies.is_a?(Array)
          setup_supply_chain_components(dependencies, components, seen)
        end
      end
      components
    end

    def setup_audit_severity_counts(value)
      counts = { "critical" => 0, "high" => 0, "moderate" => 0, "low" => 0 }
      setup_collect_audit_severities(value).each do |severity|
        next unless counts.key?(severity)

        counts[severity] += 1
      end
      metadata_counts = value.is_a?(Hash) ? value.dig("metadata", "vulnerabilities") : nil
      if metadata_counts.is_a?(Hash)
        counts.keys.each { |severity| counts[severity] = [counts[severity], metadata_counts[severity].to_i].max }
      end
      counts
    end

    def setup_collect_audit_severities(value, severities = [])
      case value
      when Array
        value.each { |item| setup_collect_audit_severities(item, severities) }
      when Hash
        severity = value["severity"].to_s.downcase
        severities << severity if %w[critical high moderate low].include?(severity)
        value.each_value { |child| setup_collect_audit_severities(child, severities) if child.is_a?(Hash) || child.is_a?(Array) }
      end
      severities
    end

    def setup_supply_chain_sbom_argv(package_manager)
      case package_manager.to_s
      when "pnpm" then ["pnpm", "list", "--json", "--depth", "Infinity"]
      else [package_manager.to_s, "list", "--json"]
      end
    end

    def setup_supply_chain_audit_argv(package_manager)
      case package_manager.to_s
      when "pnpm" then ["pnpm", "audit", "--json"]
      else [package_manager.to_s, "audit", "--json"]
      end
    end

  end
end
