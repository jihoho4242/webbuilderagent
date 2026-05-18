# frozen_string_literal: true

module Aiweb
  module Brain
    class SearchProjection
      def self.status
        { "schema_version" => 1, "status" => "local_mvp", "global_rerank" => false }
      end
    end
  end
end
