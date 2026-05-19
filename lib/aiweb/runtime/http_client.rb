# frozen_string_literal: true

require "net/http"
require "timeout"

module Aiweb
  module Runtime
    class HttpClient
      def request(spec)
        response = nil
        Timeout.timeout(spec.timeout) do
          request = Net::HTTP::Post.new(spec.uri)
          spec.headers.each { |key, value| request[key] = value }
          request.body = spec.body.to_s unless spec.body.nil?
          Net::HTTP.start(spec.uri.hostname, spec.uri.port, use_ssl: spec.uri.scheme == "https", read_timeout: spec.timeout, open_timeout: spec.timeout) do |http|
            response = http.request(request)
          end
        end
        HttpResult.new(
          status: response.is_a?(Net::HTTPSuccess) ? "passed" : "http_error",
          code: response.code.to_s,
          body: truncate(response.body.to_s, spec.max_body_bytes),
          headers: response.each_header.to_h
        )
      rescue Timeout::Error => e
        HttpResult.new(status: "timeout", error_class: e.class.name, error_message: e.message)
      rescue StandardError => e
        HttpResult.new(status: "transport_error", error_class: e.class.name, error_message: e.message)
      end

      private

      def truncate(value, max)
        text = value.to_s
        text.bytesize > max ? text.byteslice(0, max).to_s + "\n[truncated]" : text
      end
    end
  end
end
