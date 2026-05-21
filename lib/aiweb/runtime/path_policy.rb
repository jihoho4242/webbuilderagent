# frozen_string_literal: true

module Aiweb
  module Runtime
    module PathPolicy
      SECRET_LOOKING_PATH_PATTERN = %r{
        (?:
          (?:\A|/)\.ssh(?:/|\z)|
          (?:\A|/)(?:secret|secrets|private|credentials?)(?:[._-][^/\s`"'<>]+)?(?:/|\z)|
          (?:\A|/)[^/\s`"'<>]*(?:private[_-]?key|id_rsa|id_dsa|id_ed25519|credential|secret)[^/\s`"'<>]*\.(?:txt|json|ya?ml|pem|key|env)\z|
          (?:\A|/)[^/\s`"'<>]*\.(?:pem|key)\z
        )
      }ix.freeze
      SECRET_SURFACE_DIRS = %w[
        .ssh
        .aws
        .azure
        .gcloud
        .docker
        .kube
        .vercel
        .netlify
      ].freeze
      SECRET_SURFACE_FILES = %w[
        .npmrc
        .yarnrc
        .pypirc
        .netrc
        id_rsa
        id_dsa
        id_ed25519
      ].freeze
      BROWSER_SECRET_SURFACE_PATTERN = %r{
        (?:
          (?:\A|/)\.config/(?:google-chrome|chromium)(?:/|\z)|
          (?:\A|/)\.mozilla(?:/|\z)|
          (?:\A|/)(?:Cookies|Login\ Data|Local\ State|Local\ Storage|Session\ Storage)(?:/|\z)
        )
      }x.freeze

      module_function

      def normalize_relative(path)
        value = path.to_s.strip.tr("\\", "/")
        value = value.sub(%r{\A(?:\./)+}, "")
        value
      end

      def unsafe_env_path?(path)
        normalize_relative(path).split("/").any? { |part| part == ".env" || part.start_with?(".env.") }
      end

      def secret_looking_path?(path)
        normalize_relative(path).match?(SECRET_LOOKING_PATH_PATTERN)
      end

      def secret_surface_path?(path)
        normalized = normalize_relative(path)
        return true if unsafe_env_path?(normalized) || secret_looking_path?(normalized)

        parts = normalized.split("/")
        return true if parts.any? { |part| SECRET_SURFACE_DIRS.include?(part) }
        return true if parts.any? { |part| SECRET_SURFACE_FILES.include?(part) }
        return true if normalized.match?(BROWSER_SECRET_SURFACE_PATTERN)

        false
      end

      def traversal_path?(path)
        normalize_relative(path).split("/").any? { |part| part == ".." }
      end

      def absolute_path?(path)
        value = path.to_s.strip
        value.start_with?("/") || value.match?(%r{\A[A-Za-z]:[\\/]})
      end

      def safe_relative_path?(path, allow_secret: false)
        normalized = normalize_relative(path)
        return false if normalized.empty? || absolute_path?(path) || traversal_path?(normalized) || unsafe_env_path?(normalized)
        return false if !allow_secret && secret_looking_path?(normalized)

        true
      end

      def safe_workspace_path?(root, path, allow_secret: false, must_exist: false)
        return false unless safe_relative_path?(path, allow_secret: allow_secret)

        root_real = File.realpath(root)
        candidate = File.expand_path(normalize_relative(path), root_real)
        return false unless inside_directory?(root_real, candidate)
        return !must_exist unless File.exist?(candidate)

        inside_directory?(root_real, File.realpath(candidate))
      rescue SystemCallError, ArgumentError
        false
      end

      def validate_relative!(path, allow_secret: false, label: "path")
        return normalize_relative(path) if safe_relative_path?(path, allow_secret: allow_secret)

        raise ArgumentError, "unsafe #{label}: #{path.inspect}"
      end

      def validate_workspace!(root, path, allow_secret: false, must_exist: false, label: "path")
        return normalize_relative(path) if safe_workspace_path?(root, path, allow_secret: allow_secret, must_exist: must_exist)

        raise ArgumentError, "unsafe #{label}: #{path.inspect}"
      end

      def inside_directory?(root, candidate)
        root = File.expand_path(root)
        candidate = File.expand_path(candidate)
        prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
        candidate == root || candidate.start_with?(prefix)
      end
    end
  end
end
