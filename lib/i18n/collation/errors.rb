# frozen_string_literal: true

module I18n
  module Collation
    class Error < StandardError; end
    class IncompatibleCollationError < Error; end
    class InvalidWeightTableError < Error; end
  end
end
