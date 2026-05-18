# frozen_string_literal: true

require_relative "governor"

module Aiweb
  module SelfImprovement
    class ProposalGenerator
      def initialize(governor = Governor.new)
        @governor = governor
      end

      def propose(**kwargs)
        @governor.dry_run_proposal(**kwargs)
      end
    end
  end
end
