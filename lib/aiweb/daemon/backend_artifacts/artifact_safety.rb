# frozen_string_literal: true

require_relative "../../authz_contract"

module Aiweb
  module BackendArtifacts
    def run_artifact_refs(root, run_id, metadata)
      refs = []
      metadata.to_h.each do |key, value|
        next unless key.end_with?("_path") || key == "diff_path"

        relative = value.to_s
        next if relative.empty?
        next unless safe_artifact_reference?(root, relative)

        refs << artifact_ref(root, relative, artifact_role(key, relative))
      end
      Dir.glob(File.join(root, ".ai-web", "runs", run_id, "{artifacts,logs,qa,screenshots}", "*")).sort.each do |file|
        next unless File.file?(file)

        relative = file.sub(%r{\A#{Regexp.escape(root)}/?}, "").tr("\\", "/")
        next unless safe_artifact_reference?(root, relative)

        refs << artifact_ref(root, relative, artifact_role(File.basename(file, ".*"), relative))
      end
      refs.uniq { |entry| entry["path"] }
    end

    def safe_artifact_reference?(root, relative)
      safe_artifact_path!(root, relative)
      true
    rescue UserError
      false
    end

    def artifact_ref(root, relative, role)
      full = File.join(root, relative)
      {
        "path" => relative,
        "role" => role,
        "media_type" => artifact_media_type(relative),
        "size_bytes" => File.file?(full) ? File.size(full) : nil
      }.compact
    end

    def artifact_role(key, relative)
      return "diff" if key == "diff_path" || relative.end_with?(".patch")

      key.sub(/_path\z/, "")
    end

    def artifact_acl_classification(relative)
      normalized = relative.to_s.tr("\\", "/")
      required_role = if normalized.match?(%r{\A\.ai-web/runs/[^/]+/approvals\.jsonl\z})
                        "admin"
                      elsif normalized.start_with?(".ai-web/diffs/") ||
                          normalized.match?(%r{\A\.ai-web/runs/[^/]+/logs/}) ||
                          normalized.match?(%r{\A\.ai-web/runs/[^/]+/artifacts/(?:agent-result|authz-enforcement|sandbox-preflight|supply-chain-gate|worker-adapter|mcp-broker|side-effect-broker)[A-Za-z0-9_.-]*\.(?:json|jsonl|log|txt|md)\z})
                        "operator"
                      else
                        "viewer"
                      end
      {
        "policy" => Aiweb::AuthzContract::ARTIFACT_ACL_POLICY.fetch("policy"),
        "required_role" => required_role,
        "category" => required_role == "viewer" ? "standard_safe_artifact" : "sensitive_run_artifact",
        "reason" => required_role == "viewer" ? "safe artifact allowlist and viewer role are sufficient" : "logs, diffs, approvals, and sensitive run artifacts require elevated project role"
      }
    end

    def safe_artifact_path!(root, artifact)
      text = artifact.to_s.strip
      raise UserError.new("artifact path is required", 1) if text.empty?
      raise UserError.new("artifact path must be relative", 5) if text.start_with?("/") || text.match?(/\A[a-z][a-z0-9+.-]*:\/\//i)
      raise UserError.new("unsafe artifact path blocked: null bytes are not allowed", 5) if text.include?("\x00")
      raise UserError.new("unsafe artifact path blocked: .env/.env.* paths are not allowed", 5) if unsafe_env_path?(text)

      normalized = text.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
      parts = normalized.split("/")
      if normalized.empty? || parts.any? { |part| part.empty? || part == ".." }
        raise UserError.new("unsafe artifact path blocked: path traversal is not allowed", 5)
      end
      unless normalized.match?(self.class::SAFE_ARTIFACT_PATTERN)
        raise UserError.new("artifact path is not on the safe read allowlist: #{normalized}", 5)
      end

      full = File.expand_path(normalized, root)
      aiweb_root = File.expand_path(File.join(root, ".ai-web"))
      unless full == aiweb_root || full.start_with?("#{aiweb_root}#{File::SEPARATOR}")
        raise UserError.new("unsafe artifact path blocked: artifact must stay under .ai-web", 5)
      end
      normalized
    end

    def safe_artifact_realpath!(root, full, relative)
      raise UserError.new("artifact symlinks are not readable: #{relative}", 5) if File.lstat(full).symlink?

      real = File.realpath(full)
      aiweb_root = File.realpath(File.join(root, ".ai-web"))
      unless real.start_with?("#{aiweb_root}#{File::SEPARATOR}")
        raise UserError.new("unsafe artifact path blocked: artifact must stay under .ai-web", 5)
      end
      true
    rescue Errno::ENOENT
      raise UserError.new("artifact does not exist: #{relative}", 1)
    end

    def artifact_media_type(path)
      case File.extname(path).downcase
      when ".json" then "application/json"
      when ".jsonl" then "application/x-jsonlines"
      when ".patch" then "text/x-diff"
      when ".html" then "text/html"
      when ".md" then "text/markdown"
      when ".log" then "text/plain"
      when ".png" then "image/png"
      when ".yml", ".yaml" then "application/yaml"
      else "text/plain"
      end
    end

    def safe_artifact_json(path, content)
      return nil unless File.extname(path).downcase == ".json"

      safe_metadata(JSON.parse(content))
    rescue JSON::ParserError
      nil
    end
  end
end
