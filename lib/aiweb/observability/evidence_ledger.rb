# frozen_string_literal: true

require "digest"
require "json"
require "time"

module Aiweb
  module Observability
    class EvidenceLedger
      def initialize
        @events = []
      end

      def append(type, payload = {})
        previous = @events.last && @events.last["event_hash"]
        event = { "schema_version" => 1, "seq" => @events.length + 1, "type" => type, "payload" => payload, "previous_event_hash" => previous, "at" => Time.now.utc.iso8601 }
        event["event_hash"] = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(event))}"
        @events << event
        event
      end

      attr_reader :events
    end
  end
end
