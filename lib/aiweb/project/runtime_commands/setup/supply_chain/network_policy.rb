# frozen_string_literal: true

module Aiweb
  module ProjectRuntimeCommands
    private

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
  end
end
