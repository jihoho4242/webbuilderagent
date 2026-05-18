# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "openssl"
require "rbconfig"
require "time"

require_relative "../errors"
require_relative "local_backend_authz/project_registry"
require_relative "local_backend_authz/claims"
require_relative "local_backend_authz/tokens"

module Aiweb
  module LocalBackendAuthz
    private

    def backend_project_claim_id(root)
      entry = authz_project_entries.find { |candidate| canonical_path_equal?(root, candidate.fetch(:root)) }
      entry&.fetch(:project_id, nil).to_s
    end

    def canonical_path_equal?(left, right)
      left_path = File.expand_path(left.to_s)
      right_path = File.expand_path(right.to_s)
      if RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/i)
        left_path.casecmp?(right_path)
      else
        left_path == right_path
      end
    end

    def secure_token_equal?(left, right)
      return false unless left.bytesize == right.bytesize

      diff = 0
      left.bytes.zip(right.bytes) { |a, b| diff |= a ^ b }
      diff.zero?
    end
  end
end
