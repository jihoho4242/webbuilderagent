# frozen_string_literal: true

module Aiweb
  module ProfilePolicy
    module Resolver
      module_function

      def fetch(profile)
        case profile.to_s.upcase
        when "D"
          ProfileD.contract
        when "S"
          ProfileS.contract
        else
          nil
        end
      end

      def fetch!(profile)
        fetch(profile) || raise(ArgumentError, "runtime contract is only implemented for Profile D or Profile S; received #{profile.inspect}")
      end

      def supported?(profile)
        !fetch(profile).nil?
      end
    end
  end
end
