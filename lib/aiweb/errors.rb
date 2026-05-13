# frozen_string_literal: true

module Aiweb
  class UserError < StandardError
    attr_reader :exit_code

    def initialize(message, exit_code = 1)
      super(message)
      @exit_code = exit_code
    end
  end
end
