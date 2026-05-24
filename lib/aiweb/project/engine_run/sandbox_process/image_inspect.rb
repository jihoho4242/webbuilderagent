# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    private

    def engine_run_container_image_inspect(sandbox, image)
      return { "status" => "skipped", "reason" => "missing_sandbox_or_image" } if sandbox.to_s.strip.empty? || image.to_s.strip.empty?

      result = engine_run_sandbox_runtime_capture(sandbox, ["image", "inspect", image.to_s], risk_class: "engine_run_sandbox_image_inspect")
      return { "status" => "failed", "exit_code" => result.exit_code } unless result.success?
      return { "status" => "failed", "reason" => "image_inspect_empty_output" } if result.stdout.to_s.strip.empty?

      parsed = JSON.parse(result.stdout.to_s)
      image_record = parsed.is_a?(Array) ? parsed.first : parsed
      return { "status" => "failed", "reason" => "image_inspect_missing_record" } unless image_record.is_a?(Hash)

      repo_digests = Array(image_record["RepoDigests"]).map(&:to_s).reject(&:empty?)
      image_id = image_record["Id"].to_s
      digest = repo_digests.find { |entry| entry.include?("@sha256:") } ||
               (image_id.match?(/\Asha256:[a-f0-9]{64}\z/i) ? image_id : nil)
      return { "status" => "failed", "reason" => "image_inspect_missing_digest", "repo_digests" => repo_digests, "image_id" => image_id.empty? ? nil : image_id } if digest.to_s.empty?

      {
        "status" => "passed",
        "digest" => digest,
        "repo_digests" => repo_digests,
        "image_id" => image_id.empty? ? nil : image_id,
        "created" => image_record["Created"],
        "architecture" => image_record["Architecture"],
        "os" => image_record["Os"]
      }
    rescue JSON::ParserError
      { "status" => "failed", "reason" => "image_inspect_parse_failed" }
    rescue ArgumentError, SystemCallError => e
      { "status" => "failed", "error" => e.message }
    end

    def engine_run_container_image_digest(image, image_inspect)
      return image.to_s[/sha256:[a-f0-9]{64}/i] if engine_run_digest_pinned_image?(image)

      image_inspect.fetch("digest", nil)
    end

    def engine_run_sandbox_runtime_info(sandbox)
      return { "status" => "skipped", "reason" => "missing_sandbox" } if sandbox.to_s.strip.empty?

      result = engine_run_sandbox_runtime_capture(sandbox, ["info", "--format", "{{json .}}"], risk_class: "engine_run_sandbox_runtime_info")
      return { "status" => "failed", "exit_code" => result.exit_code, "rootless_mode" => "not_observed", "security_options" => [] } unless result.success?

      parsed = result.stdout.to_s.strip.empty? ? {} : JSON.parse(result.stdout.to_s)
      parsed = {} unless parsed.is_a?(Hash)
      security_options = Array(parsed["SecurityOptions"] || parsed.dig("Host", "Security", "SecurityOptions")).map(&:to_s)
      rootless = parsed.dig("Host", "Security", "Rootless")
      rootless = security_options.any? { |item| item.match?(/rootless/i) } if rootless.nil?
      {
        "status" => "passed",
        "rootless_mode" => rootless.nil? ? "not_observed" : (rootless ? "observed_rootless" : "observed_rootful"),
        "security_options" => security_options,
        "server_version" => parsed["ServerVersion"] || parsed["Version"],
        "driver" => parsed["Driver"],
        "cgroup_driver" => parsed["CgroupDriver"] || parsed.dig("Host", "CgroupManager")
      }
    rescue JSON::ParserError
      { "status" => "passed", "raw_parse_failed" => true, "rootless_mode" => "not_observed", "security_options" => [] }
    rescue ArgumentError, SystemCallError => e
      { "status" => "failed", "error" => e.message, "rootless_mode" => "not_observed", "security_options" => [] }
    end
  end
end
