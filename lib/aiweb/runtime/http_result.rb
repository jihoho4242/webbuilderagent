# frozen_string_literal: true

module Aiweb
  module Runtime
    class HttpResult
      attr_reader :status, :code, :body, :headers, :error_class, :error_message

      def initialize(status:, code: nil, body: "", headers: {}, error_class: nil, error_message: nil)
        @status = status
        @code = code
        @body = body.to_s
        @headers = headers
        @error_class = error_class
        @error_message = error_message
      end

      def success?
        status == "passed"
      end
    end
  end
end
