# frozen_string_literal: true

require 'i18n/collation/errors'

module I18n
  module Collation
    NUMERIC_PREFIX = [0x12]

    class SortKey
      include Comparable

      attr_reader :config_id, :levels

      def initialize(config_id, levels, collator = nil)
        @config_id = config_id
        @levels = levels
        @collator = collator
        freeze
      end

      def <=>(other)
        return nil unless other.is_a?(SortKey)
        raise IncompatibleCollationError, incompatible_message(other) unless compatible_with?(other)

        levels.each_with_index do |level, index|
          result = compare_levels(level, other.levels[index])
          return result unless result.zero?
        end
        0
      end

      def ==(other)
        return false unless other.is_a?(SortKey)

        raise IncompatibleCollationError, incompatible_message(other) unless compatible_with?(other)

        levels == other.levels
      end
      alias_method :eql?, :==

      def hash
        [config_id, levels].hash
      end

      def compatible_with?(other)
        case other
        when SortKey
          config_id == other.config_id
        when Collator
          config_id == other.config_id
        else
          false
        end
      end
      alias_method :compatible?, :compatible_with?

      def to_a
        levels
      end

      def to_s
        level_strings = levels.map do |level|
          level.map do |weight|
            next weight unless weight.is_a?(Array)
            next weight.map(&:to_s).join('.') if weight.first == :numeric

            weight.pack('C*')
          end.join
        end
        level_strings.join("\0")
      end

      def inspect
        "#<#{self.class} config_id=#{config_id} levels=#{levels.inspect}>"
      end

      private

      def incompatible_message(other)
        "Cannot compare collation keys from incompatible configurations: #{config_id} and #{other.config_id}"
      end

      def compare_levels(left, right)
        left.each_with_index do |weight, index|
          return -1 if index >= right.length

          result = compare_weights(weight, right[index])
          return result unless result.zero?
        end
        0
      end

      def compare_weights(left, right)
        if left.is_a?(Array) && right.is_a?(Array)
          if left.first == :numeric && right.first == :numeric
            compare_numeric(left, right)
          elsif left.first == :numeric
            compare_numeric_with_ordinary(left, right)
          elsif right.first == :numeric
            -compare_numeric_with_ordinary(right, left)
          else
            left <=> right
          end
        elsif left.is_a?(Array)
          1
        elsif right.is_a?(Array)
          -1
        else
          left <=> right
        end
      end

      def compare_numeric(left, right)
        left_digits = left[2..]
        right_digits = right[2..]
        length = left_digits.length <=> right_digits.length
        return length unless length.zero?

        left_digits <=> right_digits
      end

      def compare_numeric_with_ordinary(numeric, ordinary)
        numeric_prefix <=> ordinary
      end

      def numeric_prefix
        NUMERIC_PREFIX
      end

    end
  end
end
