# encoding: utf-8
# frozen_string_literal: true

module I18n
  module Backend
    module Transliterator
      DEFAULT_REPLACEMENT_CHAR = "?"

      # Given a locale and a UTF-8 string, return the locale's ASCII
      # approximation for the string.
      def transliterate(locale, string, replacement = nil)
        transliterator_for(locale).transliterate(string, replacement)
      end

      # Like #transliterate, but returns the output as a list of Segments.
      # Each segment carries the output text and the codepoint range of the
      # original input it was produced from.
      def transliterate_segments(locale, string, replacement = nil)
        transliterator_for(locale).transliterate_segments(string, replacement)
      end

      # Get a transliterator instance.
      #
      # * +nil+ or a Hash of single characters: HashTransliterator
      # * a Proc: ProcTransliterator
      # * an Array of declarative rule entries: RuleTransliterator
      def self.get(rule = nil)
        case rule
        when nil, Hash
          HashTransliterator.new(rule)
        when Proc
          ProcTransliterator.new(rule)
        when Array
          RuleTransliterator.new(rule)
        else
          raise I18n::ArgumentError, "Transliteration rule must be a proc, a hash or an array of rules."
        end
      end

      # An output fragment produced by a transliterator.
      #
      # +input_start+ and +input_end+ are codepoint offsets (not byte offsets)
      # into the original input string, forming a half-open range. The
      # +matched+ flag is true when the fragment was produced by a
      # transliteration rule (including inherited single character
      # approximations), and false when the input was passed through
      # unchanged or replaced through the +replacement+ option.
      Segment = Data.define(:text, :input_start, :input_end, :matched) do
        def matched?
          matched
        end

        def input_range
          input_start...input_end
        end

        # Returns the slice of the original input string this segment was
        # produced from.
        def slice_input(string)
          string.codepoints[input_range].pack("U*")
        end
      end

      private

      def transliterator_for(locale)
        @transliterators ||= {}
        @transliterators[locale] ||= Transliterator.get(I18n.t(:'i18n.transliterate.rule',
          :locale => locale, :resolve => false, :default => {}))
      end
      # A transliterator which accepts a Proc as its transliteration rule.
      class ProcTransliterator
        def initialize(rule)
          @rule = rule
        end

        def transliterate(string, replacement = nil)
          @rule.call(string)
        end

        def transliterate_segments(string, replacement = nil)
          raise I18n::ArgumentError,
            "Cannot report input intervals for a proc transliteration rule."
        end
      end

      # A transliterator which accepts a Hash of characters as its translation
      # rule.
      class HashTransliterator
        DEFAULT_APPROXIMATIONS = {
          "À"=>"A", "Á"=>"A", "Â"=>"A", "Ã"=>"A", "Ä"=>"A", "Å"=>"A", "Æ"=>"AE",
          "Ç"=>"C", "È"=>"E", "É"=>"E", "Ê"=>"E", "Ë"=>"E", "Ì"=>"I", "Í"=>"I",
          "Î"=>"I", "Ï"=>"I", "Ð"=>"D", "Ñ"=>"N", "Ò"=>"O", "Ó"=>"O", "Ô"=>"O",
          "Õ"=>"O", "Ö"=>"O", "×"=>"x", "Ø"=>"O", "Ù"=>"U", "Ú"=>"U", "Û"=>"U",
          "Ü"=>"U", "Ý"=>"Y", "Þ"=>"Th", "ß"=>"ss", "ẞ"=>"SS", "à"=>"a",
          "á"=>"a", "â"=>"a", "ã"=>"a", "ä"=>"a", "å"=>"a", "æ"=>"ae", "ç"=>"c",
          "è"=>"e", "é"=>"e", "ê"=>"e", "ë"=>"e", "ì"=>"i", "í"=>"i", "î"=>"i",
          "ï"=>"i", "ð"=>"d", "ñ"=>"n", "ò"=>"o", "ó"=>"o", "ô"=>"o", "õ"=>"o",
          "ö"=>"o", "ø"=>"o", "ù"=>"u", "ú"=>"u", "û"=>"u", "ü"=>"u", "ý"=>"y",
          "þ"=>"th", "ÿ"=>"y", "Ā"=>"A", "ā"=>"a", "Ă"=>"A", "ă"=>"a", "Ą"=>"A",
          "ą"=>"a", "Ć"=>"C", "ć"=>"c", "Ĉ"=>"C", "ĉ"=>"c", "Ċ"=>"C", "ċ"=>"c",
          "Č"=>"C", "č"=>"c", "Ď"=>"D", "ď"=>"d", "Đ"=>"D", "đ"=>"d", "Ē"=>"E",
          "ē"=>"e", "Ĕ"=>"E", "ĕ"=>"e", "Ė"=>"E", "ė"=>"e", "Ę"=>"E", "ę"=>"e",
          "Ě"=>"E", "ě"=>"e", "Ĝ"=>"G", "ĝ"=>"g", "Ğ"=>"G", "ğ"=>"g", "Ġ"=>"G",
          "ġ"=>"g", "Ģ"=>"G", "ģ"=>"g", "Ĥ"=>"H", "ĥ"=>"h", "Ħ"=>"H", "ħ"=>"h",
          "Ĩ"=>"I", "ĩ"=>"i", "Ī"=>"I", "ī"=>"i", "Ĭ"=>"I", "ĭ"=>"i", "Į"=>"I",
          "į"=>"i", "İ"=>"I", "ı"=>"i", "Ĳ"=>"IJ", "ĳ"=>"ij", "Ĵ"=>"J", "ĵ"=>"j",
          "Ķ"=>"K", "ķ"=>"k", "ĸ"=>"k", "Ĺ"=>"L", "ĺ"=>"l", "Ļ"=>"L", "ļ"=>"l",
          "Ľ"=>"L", "ľ"=>"l", "Ŀ"=>"L", "ŀ"=>"l", "Ł"=>"L", "ł"=>"l", "Ń"=>"N",
          "ń"=>"n", "Ņ"=>"N", "ņ"=>"n", "Ň"=>"N", "ň"=>"n", "ŉ"=>"'n", "Ŋ"=>"NG",
          "ŋ"=>"ng", "Ō"=>"O", "ō"=>"o", "Ŏ"=>"O", "ŏ"=>"o", "Ő"=>"O", "ő"=>"o",
          "Œ"=>"OE", "œ"=>"oe", "Ŕ"=>"R", "ŕ"=>"r", "Ŗ"=>"R", "ŗ"=>"r", "Ř"=>"R",
          "ř"=>"r", "Ś"=>"S", "ś"=>"s", "Ŝ"=>"S", "ŝ"=>"s", "Ş"=>"S", "ş"=>"s",
          "Š"=>"S", "š"=>"s", "Ţ"=>"T", "ţ"=>"t", "Ť"=>"T", "ť"=>"t", "Ŧ"=>"T",
          "ŧ"=>"t", "Ũ"=>"U", "ũ"=>"u", "Ū"=>"U", "ū"=>"u", "Ŭ"=>"U", "ŭ"=>"u",
          "Ů"=>"U", "ů"=>"u", "Ű"=>"U", "ű"=>"u", "Ų"=>"U", "ų"=>"u", "Ŵ"=>"W",
          "ŵ"=>"w", "Ŷ"=>"Y", "ŷ"=>"y", "Ÿ"=>"Y", "Ź"=>"Z", "ź"=>"z", "Ż"=>"Z",
          "ż"=>"z", "Ž"=>"Z", "ž"=>"z", "Ǫ"=>"O", "ǫ"=>"o", "Ǭ"=>"O",
          "ǭ"=>"o"
        }.freeze

        def initialize(rule = nil)
          @rule = rule
          add_default_approximations
          add rule if rule
        end

        def transliterate(string, replacement = nil)
          replacement ||= DEFAULT_REPLACEMENT_CHAR
          string.gsub(/[^\x00-\x7f]/u) do |char|
            approximations[char] || (replacement == :none ? char : replacement)
          end
        end

        def transliterate_segments(string, replacement = nil)
          replacement ||= DEFAULT_REPLACEMENT_CHAR
          raise ArgumentError, "invalid byte sequence in UTF-8" unless string.valid_encoding?

          string.codepoints.each_with_index.map do |codepoint, index|
            if codepoint < 0x80
              Segment.new(codepoint.chr(Encoding::UTF_8), index, index + 1, false)
            else
              char = codepoint.chr(Encoding::UTF_8)
              value = approximations[char]
              if value
                Segment.new(value, index, index + 1, true)
              else
                value = replacement == :none ? char : replacement
                Segment.new(value, index, index + 1, false)
              end
            end
          end
        end

        private

        def approximations
          @approximations ||= {}
        end

        def add_default_approximations
          DEFAULT_APPROXIMATIONS.each do |key, value|
            approximations[key] = value
          end
        end

        # Add transliteration rules to the approximations hash.
        def add(hash)
          hash.each do |key, value|
            approximations[key.to_s] = value.to_s
          end
        end
      end

      # A transliterator driven by a list of declarative rules.
      #
      # Rules are given as an Array of entries. Each entry is either:
      #
      # * a declarative rule hash:
      #     { "pattern" => "ch", "replacement" => "tch",
      #       "left" => "word_boundary", "right" => ["a", "e"],
      #       "priority" => 2 }
      # * a one or many key hash of plain pattern => replacement pairs:
      #     { "ü" => "ue" }
      #
      # Rule fields:
      #
      # [pattern]     One or more characters to match (required). Matching is
      #               performed on input that has been normalized to a given
      #               Unicode normalization form (NFC by default), so an input
      #               of "u" + COMBINING DIAERESIS matches a pattern of "ü".
      # [replacement] The text emitted for the match (required). May be an
      #               empty string to delete the match. Replacements are
      #               emitted verbatim and are never fed back through the
      #               rules.
      # [left]        Condition on the text immediately before the match. May
      #               be a string that must appear there (it is not consumed),
      #               one of the anchors "start", "end" or "word_boundary",
      #               or an Array of alternatives.
      # [right]       Condition on the text immediately after the match, same
      #               vocabulary as +left+.
      # [priority]    Integer priority. Higher priority wins. Defaults to 0.
      #
      # At every position the winning rule is selected by: highest priority,
      # then longest pattern (the default longest valid match), then locale
      # rules over the inherited single character approximations, then
      # declaration order. A match can only start and end on grapheme cluster
      # boundaries. Single character mappings are inherited from
      # HashTransliterator::DEFAULT_APPROXIMATIONS and may be overridden.
      class RuleTransliterator
        NORMALIZATION_FORMS = [:nfc, :nfd, :nfkc, :nfkd].freeze

        # Internally a rule is represented by this value object. +source+ is
        # 0 for rules declared by the locale and 1 for the inherited default
        # approximations; +order+ is the global declaration order.
        Rule = Data.define(:pattern_cps, :replacement, :left, :right,
                           :priority, :source, :order) do
          def length
            pattern_cps.length
          end
        end

        DECLARATIVE_KEYS = %w[pattern replacement left right priority].freeze
        private_constant :DECLARATIVE_KEYS

        def initialize(rule = nil, normalization_form: :nfc)
          @normalization_form = resolve_normalization_form(normalization_form)
          @rules = []
          add_default_approximations
          Array(rule).each { |entry| add_entry(entry) }
          index_rules
        end

        def transliterate(string, replacement = nil)
          transliterate_segments(string, replacement).map(&:text).join
        end

        def transliterate_segments(string, replacement = nil)
          replacement ||= DEFAULT_REPLACEMENT_CHAR
          raise ArgumentError, "invalid byte sequence in UTF-8" unless string.valid_encoding?

          normalized, units, unit_starts, wordy = prepare(string)
          cps = normalized.codepoints
          segments = []
          index = 0

          while index < units.length
            unit = units[index]
            position = unit[:start_pos]
            rule = match_rule(cps, position, unit_starts, wordy)

            if rule
              end_position = position + rule.length
              last_index = index
              last_index += 1 while last_index + 1 < units.length &&
                                   units[last_index + 1][:start_pos] < end_position

              segments << Segment.new(rule.replacement,
                                      units[index][:orig_start],
                                      units[last_index][:orig_end],
                                      true)
              index = last_index + 1
            else
              segments << unmatched_segment(cps, unit, replacement)
              index += 1
            end
          end

          segments
        end

        private

        # Builds, from the input string:
        # * +normalized+:  the normalized string
        # * +units+:       grapheme clusters with normalized positions and
        #                  original codepoint ranges
        # * +unit_starts+: set of normalized positions that are cluster starts
        # * +wordy+:       map of codepoint => word character predicate
        def prepare(string)
          normalized_parts = []
          units = []
          unit_starts = {}
          wordy = {}
          original_start = 0
          normalized_start = 0

          string.scan(/\X/u) do |cluster|
            normalized_cluster = normalize(cluster)
            cluster_cps = normalized_cluster.codepoints
            original_length = cluster.codepoints.length
            normalized_length = cluster_cps.length

            cluster_cps.each do |codepoint|
              wordy[codepoint] = word_character?(codepoint) unless wordy.key?(codepoint)
            end

            units << {
              :start_pos  => normalized_start,
              :end_pos    => normalized_start + normalized_length,
              :orig_start => original_start,
              :orig_end   => original_start + original_length
            }
            unit_starts[normalized_start] = true
            normalized_parts << normalized_cluster
            normalized_start += normalized_length
            original_start += original_length
          end

          [normalized_parts.join, units, unit_starts, wordy]
        end

        def unmatched_segment(cps, unit, replacement)
          original = cps[unit[:start_pos]...unit[:end_pos]].pack("U*")

          text =
            if ascii_cluster?(cps, unit)
              original
            elsif replacement == :none
              original
            else
              replacement
            end

          Segment.new(text, unit[:orig_start], unit[:orig_end], false)
        end

        def ascii_cluster?(cps, unit)
          cps[unit[:start_pos]...unit[:end_pos]].all? { |codepoint| codepoint < 0x80 }
        end

        # Returns the first rule matching at +position+ or nil. Rules sharing
        # a first codepoint are pre-sorted by priority, length, source and
        # declaration order, so the first applicable rule wins.
        def match_rule(cps, position, unit_starts, wordy)
          candidates = @rules_by_first[cps[position]]
          return nil unless candidates

          candidates.each do |rule|
            end_position = position + rule.length
            next if end_position > cps.length
            next unless cps[position, rule.length] == rule.pattern_cps
            # A match must end on a grapheme cluster boundary.
            next unless end_position == cps.length || unit_starts[end_position]
            next unless conditions_match?(rule.left, position, cps, :left, wordy)
            next unless conditions_match?(rule.right, end_position, cps, :right, wordy)
            return rule
          end

          nil
        end

        # A list of conditions is satisfied when any alternative matches.
        def conditions_match?(conditions, position, cps, side, wordy)
          return true if conditions.nil?

          conditions.any? do |kind, value|
            case kind
            when :literal
              length = value.length
              if side == :right
                cps[position, length] == value
              else
                position >= length && cps[position - length, length] == value
              end
            when :start
              position == 0
            when :end
              position == cps.length
            when :word_boundary
              left_word = position > 0 && wordy[cps[position - 1]]
              right_word = position < cps.length && wordy[cps[position]]
              left_word != right_word
            else
              raise I18n::ArgumentError, "Unknown #{side} context #{value.inspect}."
            end
          end
        end

        def word_character?(codepoint)
          codepoint.chr(Encoding::UTF_8).match?(/\w/u)
        end

        def add_default_approximations
          HashTransliterator::DEFAULT_APPROXIMATIONS.each do |pattern, replacement|
            add_rule(pattern, replacement, :source => 1)
          end
        end

        def add_entry(entry)
          unless entry.is_a?(Hash)
            raise I18n::ArgumentError,
              "Transliteration rule entries must be hashes, got #{entry.inspect}."
          end

          normalized = {}
          entry.each_key { |key| normalized[key.to_s] = entry[key] }

          if normalized.key?("pattern")
            add_declarative_rule(normalized)
          else
            normalized.each { |pattern, replacement| add_rule(pattern, replacement) }
          end
        end

        def add_declarative_rule(entry)
          unknown = entry.keys - DECLARATIVE_KEYS
          unless unknown.empty?
            raise I18n::ArgumentError,
              "Unknown transliteration rule key#{unknown.length == 1 ? '' : 's'} " \
              "#{unknown.map(&:inspect).join(', ')}."
          end

          pattern = entry["pattern"]
          unless pattern.is_a?(String) || pattern.is_a?(Symbol)
            raise I18n::ArgumentError,
              "Transliteration rule pattern must be a string, got #{pattern.inspect}."
          end
          if normalize(pattern.to_s).empty?
            raise I18n::ArgumentError, "Transliteration rule is missing a non-empty pattern."
          end

          unless entry.key?("replacement")
            raise I18n::ArgumentError, "Transliteration rule for #{pattern.inspect} is missing a replacement."
          end
          unless entry["replacement"].respond_to?(:to_s)
            raise I18n::ArgumentError,
              "Transliteration rule replacement must be a string, got #{entry['replacement'].inspect}."
          end

          priority = entry.fetch("priority", 0)
          unless priority.is_a?(Integer)
            raise I18n::ArgumentError, "Transliteration rule priority must be an integer, got #{priority.inspect}."
          end

          add_rule(pattern, entry["replacement"],
                   :left     => compile_context(entry["left"], :left),
                   :right    => compile_context(entry["right"], :right),
                   :priority => priority,
                   :source   => 0)
        end

        # A context value is either a single condition or an Array of
        # alternative conditions. Conditions are literal strings, which must
        # be found immediately adjacent to the match without being consumed,
        # or one of the anchors :start, :end and :word_boundary.
        def compile_context(value, side)
          return nil if value.nil?

          values = value.is_a?(Array) ? value : [value]
          if values.empty?
            raise I18n::ArgumentError, "Transliteration rule #{side} context must not be empty."
          end

          values.map { |item| compile_condition(item, side) }
        end

        def compile_condition(item, side)
          case item.to_s
          when "start"
            [:start, item]
          when "end"
            [:end, item]
          when "word_boundary"
            [:word_boundary, item]
          else
            unless item.is_a?(String) || item.is_a?(Symbol)
              raise I18n::ArgumentError,
                "Transliteration rule #{side} context must be a string or anchor, got #{item.inspect}."
            end
            literal = normalize(item.to_s)
            if literal.empty?
              raise I18n::ArgumentError, "Transliteration rule #{side} context must not be empty."
            end
            [:literal, literal.codepoints]
          end
        end

        def add_rule(pattern, replacement, left: nil, right: nil,
                     priority: 0, source: 0)
          pattern_text = normalize(pattern.to_s)
          if pattern_text.empty?
            raise I18n::ArgumentError, "Transliteration rule pattern must not be empty."
          end

          replacement_text = normalize(replacement.to_s)
          rule = Rule.new(pattern_text.codepoints, replacement_text,
                          left, right, priority, source, @rules.length)
          @rules << rule
        end

        def index_rules
          @rules_by_first = @rules.group_by { |rule| rule.pattern_cps.first }
          @rules_by_first.each_value do |candidates|
            candidates.sort_by! do |rule|
              [-rule.priority, -rule.length, rule.source, -specificity(rule), rule.order]
            end
          end
        end

        # Rules carrying more context conditions are more specific and win
        # ties against otherwise equal, less constrained rules.
        def specificity(rule)
          [rule.left, rule.right].count { |condition| condition }
        end

        def normalize(string)
          if @normalization_form
            string.unicode_normalize(@normalization_form)
          else
            string
          end
        end

        def resolve_normalization_form(form)
          form = form.to_s.downcase.to_sym unless form.is_a?(Symbol)
          return nil if form == :none
          unless NORMALIZATION_FORMS.include?(form)
            raise I18n::ArgumentError,
              "Unknown Unicode normalization form #{form.inspect}. " \
              "Use one of #{NORMALIZATION_FORMS.map(&:inspect).join(', ')} or :none."
          end
          form
        end
      end
    end
  end
end
