# frozen_string_literal: true

require "uri"

module Aiweb
  module Runtime
    class HttpRequestSpec
      attr_reader :uri, :method, :headers, :body, :timeout, :max_body_bytes, :risk_class, :description

      def initialize(uri:, method:, headers: {}, body: nil, timeout: 30, max_body_bytes: 500_000, risk_class: "external_http", description: nil)
        @uri = URI.parse(uri.to_s)
        @method = method.to_s.upcase
        @headers = headers.transform_keys(&:to_s).transform_values(&:to_s)
        @body = body
        @timeout = timeout
        @max_body_bytes = max_body_bytes
        @risk_class = risk_class
        @description = description || "#{@method} #{@uri.host}"
        validate!
      end

      private

      def validate!
        raise ArgumentError, "http uri is required" if uri.to_s.empty?
        raise ArgumentError, "http uri must include host" if uri.host.to_s.empty?
        raise ArgumentError, "http method must be POST" unless method == "POST"
        raise ArgumentError, "http timeout must be positive" unless Float(timeout).positive?
        raise ArgumentError, "http max_body_bytes must be positive" unless Integer(max_body_bytes).positive?
      rescue URI::InvalidURIError
        raise ArgumentError, "http uri is invalid"
      end
    end
  end
end
