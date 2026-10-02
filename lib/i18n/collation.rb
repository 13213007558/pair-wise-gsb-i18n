# frozen_string_literal: true

require 'digest'
require 'i18n/collation/errors'
require 'i18n/collation/sort_key'
require 'i18n/collation/weight_table'

module I18n
  module Collation
    UCA_VERSION = '15.1.0'
    DEFAULT_DATA_PATH = File.expand_path('collation/data/fractional_uca-15.1.0.txt', __dir__)

    def self.new(weights: nil, tailoring: {}, locale: :root, data_path: nil,
                numeric: false, ignore_punctuation: false, version: nil)
      path = data_path || (weights == :uca ? DEFAULT_DATA_PATH : nil)
      table = WeightTable.build(weights, tailoring, path: path,
                                                 version: version || (weights == :uca ? UCA_VERSION : nil))
      Collator.new(table, locale: locale, numeric: numeric,
                          ignore_punctuation: ignore_punctuation)
    end

    def self.uca(**options)
      new(**options, weights: :uca)
    end

    class Collator
      include Comparable

      attr_reader :locale, :table, :numeric, :ignore_punctuation, :config_id

      def initialize(table, locale: :root, numeric: false, ignore_punctuation: false)
        @table = table
        @locale = locale.to_sym
        @numeric = numeric
        @ignore_punctuation = ignore_punctuation
        @config_id = Digest::SHA256.hexdigest(Marshal.dump(fingerprint))[0, 16]
        freeze
      end

      def [](string)
        collation_key(string)
      end

      def collation_key(string)
        SortKey.new(config_id, build_levels(normalize(string)), self)
      end
      alias_method :sort_key, :collation_key
      alias_method :key, :collation_key

      def compare(left, right)
        result = collation_key(left) <=> collation_key(right)
        raise IncompatibleCollationError, 'cannot compare collation keys from incompatible configurations' if result.nil?

        result
      end
      alias_method :collate?, :compare

      def <=>(other)
        return nil unless other.is_a?(Collator)

        config_id <=> other.config_id
      end

      def compatible_with?(other)
        case other
        when SortKey
          other.compatible_with?(self)
        when Collator
          config_id == other.config_id
        else
          false
        end
      end
      alias_method :compatible?, :compatible_with?

      def sort(strings)
        strings
          .each_with_index
          .sort_by { |string, index| [collation_key(string), index] }
          .map(&:first)
      end

      def sort_by(enumerable, &block)
        enumerable
          .each_with_index
          .sort_by { |item, index| [collation_key(block.call(item)), index] }
          .map(&:first)
      end

      def with(**changes)
        self.class.new(
          changes.fetch(:table, table),
          locale: changes.fetch(:locale, locale),
          numeric: changes.fetch(:numeric, numeric),
          ignore_punctuation: changes.fetch(:ignore_punctuation, ignore_punctuation)
        )
      end

      def fingerprint
        {
          weights: table.fingerprint,
          locale: locale,
          numeric: numeric,
          ignore_punctuation: ignore_punctuation
        }
      end

      private

      def normalize(string)
        string.to_s.unicode_normalize(:nfd)
      end

      def build_levels(string)
        elements = tokenize(string)
        levels = [[], [], []]

        elements.each do |element|
          element.each_with_index do |weights, level|
            next if weights.nil? || weights.empty?

            values = level.positive? ? weights.reject { |weight| weight == 0 || weight == [0x80] } : weights
            levels[level].concat(values)
          end
        end

        levels[1] = compress_common_weights(levels[1])
        levels[2] = compress_common_weights(levels[2])
        levels
      end

      def tokenize(string)
        graphemes = string.chars
        elements = []
        position = 0

        while position < graphemes.length
          codepoint = graphemes[position]

          if ignore_punctuation && punctuation?(codepoint)
            position += 1
            next
          end

          if numeric && ascii_digit?(codepoint)
            finish = position
            finish += 1 while finish < graphemes.length && ascii_digit?(graphemes[finish])
            number = string[position...finish]
            elements.concat(number_elements(number))
            position = finish
            next
          end

          codepoints, consumed, skipped = match_contraction(graphemes, position)
          mapped = table.elements_for(codepoints) || table.default_elements_for(codepoints)
          if consumed > 1 && mapped.all? { |element| element[0].empty? } && skipped.empty?
            starter = table.elements_for(graphemes[position]) || table.default_elements_for(graphemes[position])
            mapped = starter + mapped
          end
          elements.concat(mapped)
          skipped.sort.each do |offset|
            source = graphemes[offset]
            skipped_elements = table.elements_for(source) || table.default_elements_for(source)
            insertion_point = elements.length
            unless skipped_elements.all? { |element| element[0].empty? }
              insertion_point = 0
              insertion_point += 1 while insertion_point < elements.length && elements[insertion_point][0].any?
            end
            elements.insert(insertion_point, *skipped_elements)
          end
          position += consumed
        end

        elements
      end

      def match_contraction(graphemes, position)
        match = table.match_canonical(graphemes, position)
        return [graphemes[position], 1, []] unless match
        relative_consumed, relative_skipped, matched_count = match
        return [graphemes[position], 1, []] if matched_count < 2
        finish = position + relative_consumed - 1
        skipped = relative_skipped.map { |offset| offset + position }
        matched_indices = (position..finish).to_a - skipped
        [matched_indices.map { |index| graphemes[index] }.join, finish - position + 1, skipped]
      end

      def number_elements(number)
        [
          [number_primary(number), [], []],
          *number.chars.map { |digit| table.elements_for(digit) || table.default_elements_for(digit) }
        ]
      end

      def number_primary(number)
        digits = number.delete_prefix('0').chars.map { |digit| digit.ord - '0'.ord }
        digits = [0] if digits.empty?
        [[:numeric, digits.length, *digits]]
      end

      def punctuation?(codepoint)
        /\A\p{P}\z/.match?(codepoint)
      end

      def ascii_digit?(codepoint)
        codepoint >= '0' && codepoint <= '9'
      end

      def compress_common_weights(weights)
        return [] if weights.empty?

        compressed = []
        common_count = 0

        weights.each do |weight|
          if weight == 5
            common_count += 1
            next
          end

          if common_count.positive?
            while common_count >= 33
              compressed << 0x25
              common_count -= 33
            end
            compressed << (weight < 5 ? 5 + common_count - 1 : 0x45 - common_count) if common_count.positive?
            common_count = 0
          end
          compressed << weight
        end

        compressed.empty? ? [2] : compressed
      end
    end
  end
end
