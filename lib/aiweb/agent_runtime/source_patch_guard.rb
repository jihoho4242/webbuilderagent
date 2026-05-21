# frozen_string_literal: true

require_relative "../runtime/source_patch_guard"

module Aiweb
  module AgentRuntime
    SourcePatchGuard = Aiweb::Runtime::SourcePatchGuard unless const_defined?(:SourcePatchGuard, false)
  end
end
