# frozen_string_literal: true

require 'pathname'
require 'i18n/collation/errors'

module I18n
  module Collation
    class WeightTable
      attr_reader :version, :entries, :fingerprint

      def self.build(weights, tailoring, path: nil, version: nil)
        case weights
        when :uca
          parse_fractional_uca(path, version, tailoring)
        when nil, false
          new(tailoring, version: version || 'custom')
        when {}
          new({}, version: version || 'empty')
        when String, Pathname
          parse_fractional_uca(weights.to_s, version, tailoring)
        when Hash
          new(weights.merge(tailoring), version: version || 'custom')
        else
          raise InvalidWeightTableError, "unsupported collation weights: #{weights.class}"
        end
      end

      def self.parse_fractional_uca(path, version = nil, tailoring = {})
        entries = {}
        detected_version = version
        han_ranges = []

        File.foreach(path, encoding: 'UTF-8') do |line|
          line = line.chomp.sub(/\A\uFEFF/, '')
          detected_version ||= Regexp.last_match(1) if line =~ /UCA version\s*=\s*([0-9.]+)/
          if line =~ /\A\[Unified_Ideograph\s+(.+)\]\z/
            han_ranges = parse_unicode_ranges(Regexp.last_match(1))
          end
          next unless line =~ /\A([0-9A-F]+(?:\s*\|?\s*[0-9A-F]+)*)\s*;\s*(.*?)(?:\s*#.*)?\z/

          source_text = Regexp.last_match(1)
          field = Regexp.last_match(2)
          raise InvalidWeightTableError, "missing weights on line: #{line}" if field.nil? || field.empty?

          source = codepoints(source_text.gsub(/\s*\|\s*/, ' '))
          entries[source] = parse_elements(field)
        end

        combining_classes = parse_combining_classes(File.join(File.dirname(path), 'UnicodeData.txt'))
        new(entries.merge(tailoring), version: detected_version || 'uca', han_ranges: han_ranges,
            normalize_sources: false, combining_classes: combining_classes)
      end

      def self.parse_combining_classes(path)
        {}.tap do |classes|
          next classes unless File.file?(path)

          File.foreach(path, encoding: 'UTF-8') do |line|
            fields = line.chomp.split(';')
            codepoint = fields[0].to_i(16)
            ccc = fields[3].to_i
            classes[codepoint.chr(Encoding::UTF_8)] = ccc if ccc.positive? && codepoint <= 0x10FFFF && !(codepoint >= 0xD800 && codepoint <= 0xDFFF)
          end
        end
      end

      def self.parse_unicode_ranges(field)
        offset = 0
        field.split.map do |token|
          start_text, end_text = token.split('..', 2)
          start = start_text.to_i(16)
          finish = end_text ? end_text.to_i(16) : start
          range = [start, finish, offset]
          offset += finish - start + 1
          range
        end
      end

      def self.codepoints(field)
        field.strip.split.map { |value| value.to_i(16) }.pack('U*')
      end

      def self.parse_elements(field)
        field.scan(/\[([^\]]*)\]/).flatten.map do |body|
          levels = body.split(',', 3)
          if levels[0].strip.start_with?('U+')
            codepoint = levels[0].strip[2..].to_i(16)
            if levels.length == 2
              tertiary = parse_weights(levels[1]).map { |weight| normalize_parsed_tertiary(weight) }
              next [[[:han, codepoint]], [], tertiary.compact]
            elsif levels.length == 1
              next [[[:han, codepoint]], [], []]
            else
              secondary = parse_weights(levels[1]).map { |weight| weight.is_a?(Array) ? weight : normalize_parsed_secondary(weight) }
              tertiary = parse_weights(levels[2]).map { |weight| normalize_parsed_tertiary(weight) }
              next [[[:han, codepoint]], secondary.compact, tertiary.compact]
            end
          end
          raise InvalidWeightTableError, "expected three weight levels: #{body.inspect}" if levels.length != 3

          secondary = parse_weights(levels[1]).map { |weight| weight.is_a?(Array) ? weight : normalize_parsed_secondary(weight) }
          tertiary = parse_weights(levels[2]).map { |weight| normalize_parsed_tertiary(weight) }
          [primary_weights(levels[0]), secondary.compact, tertiary.compact]
        end
      end

      def self.primary_weights(field)
        bytes = weight_bytes(field)
        bytes.empty? ? [] : [bytes]
      end

      def self.parse_weights(field)
        bytes = weight_bytes(field)
        bytes.length > 1 ? [bytes] : bytes
      end

      def self.weight_bytes(field)
        field.strip.split(/\s+/).reject(&:empty?).map do |token|
          raise InvalidWeightTableError, "unexpected collation weight: #{token.inspect}" if token.start_with?('U+')

          token.to_i(16)
        end
      end

      def self.unassigned_weight(codepoint)
        value = codepoint + 1
        fourth = 2 + (value % 18) * 14
        value /= 18
        third = 2 + (value % 254)
        value /= 254
        second = 4 + (value % 251)
        [0xFE, second, third, fourth]
      end

      def self.normalize_parsed_secondary(weight)
        return weight if weight <= 0x45
        return nil if weight >= 0x80

        weight - 0x6A
      end

      def self.normalize_parsed_tertiary(weight)
        weight = weight.first if weight.is_a?(Array) && weight.length == 1
        return weight if weight.is_a?(Array)
        return nil if weight.nil?
        return nil if weight >= 0x3C
        return 5 if weight & 0x40 == 0

        weight & 0x3f
      end

      def initialize(entries, version:, han_ranges: [], normalize_sources: true, combining_classes: {})
        @entries = {}.tap do |compiled|
          contractions = {}
          entries.each do |source, value|
            value = normalize_value(value)
            key = normalize_sources ? normalize_source(source) : source.to_s
            compiled[key] = value
            normalized = normalize_source(source)
            if !normalize_sources
              if value.length > 1
                contractions[normalized] = value
              elsif normalized != key
                compiled[normalized] ||= value
              end
            end
          end
          contractions.each { |key, value| compiled[key] ||= value }
        end
        @version = version
        @han_ranges = han_ranges
        @ccc = combining_classes
        @entries.each_value do |elements|
          elements.each do |element|
            element[0].map! { |token| resolve_token(token) }
          end
        end
        @trie = build_trie
        @fingerprint = { version: @version, entries: @entries }
        freeze
      end

      def elements_for(source)
        entries[source]
      end

      def default_elements_for(source)
        [[[han_weight(source.ord)], [], [source.ord]]]
      end

      def longest_prefix(string)
        node = @trie
        found = nil

        string.each_char.with_index(1) do |codepoint, length|
          node = node[codepoint]
          break unless node
          found = length if node.key?(:value)
        end

        found
      end

      def match_canonical(graphemes, start)
        starter = @trie[graphemes[start]]
        starter ? canonical_search(starter, start + 1, start + 1, graphemes, 0, 1) : nil
      end

      def canonical_search(node, next_position, index, graphemes, minimum_ccc, length)
        best = node.key?(:value) ? [index, [], length] : nil

        (next_position...graphemes.length).each do |candidate|
          codepoint = graphemes[candidate]
          ccc = canonical_combining_class(codepoint)
          break if ccc.zero? && candidate > index
          next if ccc <= minimum_ccc

          child = node[codepoint]
          next unless child

          new_length = length + 1
          result = canonical_search(child, candidate + 1, index, graphemes, ccc, new_length)
          next unless result

          finish, skipped, = result
          return [finish, (candidate == next_position ? [] : [candidate]) + skipped, new_length]
        end

        best
      end

      def han_weight(codepoint)
        start, _finish, offset_count = @han_ranges.find { |from, to, _| codepoint >= from && codepoint <= to }
        return self.class.unassigned_weight(codepoint) unless start

        offset = (offset_count + codepoint - start) * 2
        [0xFB + offset / (254 * 254), 0x20 + (offset / 254) % 254, 0x20 + offset % 254]
      end

      def resolve_token(token)
        token.is_a?(Array) && token.first == :han ? han_weight(token.last) : token
      end

      private

      def normalize_source(source)
        source.to_s.unicode_normalize(:nfd)
      end

      def combining?(codepoint)
        /\A\p{Mn}\z/.match?(codepoint) || /\A\p{Me}\z/.match?(codepoint)
      end

      def canonical_combining_class(codepoint)
        @ccc[codepoint] || 0
      end

      def normalize_value(value)
        case value
        when Hash
          if value.key?(:elements) || value.key?('elements')
            normalize_value(value[:elements] || value['elements'])
          else
            [normalize_levels(value)]
          end
        when Array
          if value.empty?
            []
          elsif value.all? { |item| element?(item) }
            value
          elsif value.any? { |item| item.is_a?(Array) && item.length == 3 }
            value.map { |element| element.map { |level| Array(level) } }
          elsif value.all? { |item| item.is_a?(Integer) || primary_token?(item) }
            [value.map { |item| item.is_a?(Array) ? item : [item] }, [], []]
          elsif value.length == 3 && value.all? { |level| level.is_a?(Array) }
            [value]
          else
            raise InvalidWeightTableError, "cannot normalize collation weights: #{value.inspect}"
          end
        else
          raise InvalidWeightTableError, "unsupported collation weight value: #{value.class}"
        end
      end

      def element?(value)
        value.is_a?(Array) && value.length == 3 && value[0].is_a?(Array) &&
          value[1].is_a?(Array) && value[2].is_a?(Array)
      end

      def normalize_levels(hash)
        levels = [[], [], []]
        hash.each do |key, weights|
          index = case key.to_sym
                  when :primary, :p then 0
                  when :secondary, :s then 1
                  when :tertiary, :t then 2
                  else raise InvalidWeightTableError, "unknown collation level: #{key.inspect}"
                  end
          values = Array(weights)
          values = values.map { |weight| weight.is_a?(Array) ? weight : [weight] } if index.zero?
          levels[index].concat(values)
        end
        levels
      end

      def primary_token?(value)
        value.is_a?(Array) && value.all? { |part| part.is_a?(Integer) || part == :numeric }
      end

      def build_trie
        root = {}

        entries.each_key do |source|
          node = root
          source.each_char { |codepoint| node = node[codepoint] ||= {} }
          node[:value] = true
        end

        root
      end
    end
  end
end
