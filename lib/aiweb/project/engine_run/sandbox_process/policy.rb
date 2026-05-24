# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    private

    def engine_run_digest_pinned_image?(image)
      image.to_s.include?("@sha256:")
    end

    def engine_run_require_digest_pinned_openmanus_image?
      !engine_run_digest_pinned_openmanus_policy_sources.empty?
    end

    def engine_run_required_sandbox_runtime_matrix
      engine_run_sandbox_runtime_matrix_tokens.select { |runtime| %w[docker podman].include?(runtime) }.uniq
    end

    def engine_run_invalid_sandbox_runtime_matrix
      engine_run_sandbox_runtime_matrix_tokens.reject { |runtime| %w[docker podman].include?(runtime) }.uniq
    end

    def engine_run_sandbox_runtime_matrix_tokens
      raw = ENV["AIWEB_ENGINE_RUN_RUNTIME_MATRIX"].to_s
      raw = "docker,podman" if raw.strip.empty? && engine_run_truthy_env?(ENV["AIWEB_ENGINE_RUN_REQUIRE_RUNTIME_MATRIX"])
      raw = "docker,podman" if raw.strip.empty? && engine_run_truthy_env?(ENV["AIWEB_REQUIRE_DOCKER_PODMAN_MATRIX"])
      raw.split(/[\s,]+/).map(&:strip).map(&:downcase).reject(&:empty?)
    end

    def engine_run_required_sandbox_runtime_matrix_policy_sources
      sources = []
      sources << "AIWEB_ENGINE_RUN_RUNTIME_MATRIX" unless ENV["AIWEB_ENGINE_RUN_RUNTIME_MATRIX"].to_s.strip.empty?
      sources << "AIWEB_ENGINE_RUN_REQUIRE_RUNTIME_MATRIX" if engine_run_truthy_env?(ENV["AIWEB_ENGINE_RUN_REQUIRE_RUNTIME_MATRIX"])
      sources << "AIWEB_REQUIRE_DOCKER_PODMAN_MATRIX" if engine_run_truthy_env?(ENV["AIWEB_REQUIRE_DOCKER_PODMAN_MATRIX"])
      sources
    end

    def engine_run_truthy_env?(value)
      %w[1 true yes on strict required].include?(value.to_s.strip.downcase)
    end

    def engine_run_digest_pinned_openmanus_policy_sources
      values = [
        ["AIWEB_OPENMANUS_REQUIRE_DIGEST", ENV["AIWEB_OPENMANUS_REQUIRE_DIGEST"]],
        ["AIWEB_REQUIRE_PINNED_OPENMANUS_IMAGE", ENV["AIWEB_REQUIRE_PINNED_OPENMANUS_IMAGE"]],
        ["AIWEB_ENGINE_RUN_STRICT_SANDBOX", ENV["AIWEB_ENGINE_RUN_STRICT_SANDBOX"]],
        ["AIWEB_ENV", ENV["AIWEB_ENV"]],
        ["AIWEB_RUNTIME_ENV", ENV["AIWEB_RUNTIME_ENV"]],
        ["AIWEB_ENGINE_RUN_ENV", ENV["AIWEB_ENGINE_RUN_ENV"]]
      ]
      values.each_with_object([]) do |(name, value), sources|
        normalized = value.to_s.strip.downcase
        next unless %w[1 true yes on strict production prod].include?(normalized)

        sources << name
      end
    end

    def engine_run_sandbox_preflight_warnings(image:, image_inspect:, runtime_info:, inside_probe:)
      warnings = []
      warnings << "container image reference is not digest-pinned" if image.to_s.strip != "" && !engine_run_digest_pinned_image?(image)
      warnings << "container image digest was not observable" if image.to_s.strip != "" && image_inspect.fetch("digest", nil).to_s.strip.empty?
      warnings << "sandbox runtime rootless/rootful mode was not observable" if runtime_info.fetch("rootless_mode", "not_observed") == "not_observed"
      warnings << "inside-container self-attestation probe did not pass" unless inside_probe.fetch("status", "not_observed") == "passed"
      warnings << "inside-container egress denial was not proven" unless inside_probe.dig("egress_denial_probe", "status") == "passed"
      warnings
    end
  end
end
