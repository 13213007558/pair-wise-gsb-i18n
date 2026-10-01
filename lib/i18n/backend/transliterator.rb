# encoding: utf-8
# frozen_string_literal: true

module I18n
  module Backend
    module Transliterator
      DEFAULT_REPLACEMENT_CHAR = "?"

      # Given a locale and a UTF-8 string, return the locale's ASCII
      # approximation for the string.
      def transliterate(locale, string, replacement = nil)
        @transliterators ||= {}
        @transliterators[locale] ||= Transliterator.get I18n.t(:'i18n.transliterate.rule',
          :locale => locale, :resolve => false, :default => {})
        @transliterators[locale].transliterate(string, replacement)
      end

      # Get a transliterator instance.
      def self.get(rule = nil, normalization_form: :nfc)
        if !rule || rule.kind_of?(Hash)
          if rule.is_a?(Hash) && rule.each_value.any? { |value| value.is_a?(Rule) }
            RuleTransliterator.new(rule, :normalization_form => normalization_form)
          else
            HashTransliterator.new(rule)
          end
        elsif rule.kind_of?(Rule)
          RuleTransliterator.new(rule, :normalization_form => normalization_form)
        elsif rule.is_a?(Array)
          RuleTransliterator.new(rule, :normalization_form => normalization_form)
        elsif rule.kind_of? Proc
          ProcTransliterator.new(rule)
        else
          raise I18n::ArgumentError, "Transliteration rule must be a proc, a hash or declarative transliteration rules."
        end
      end

      # A declarative transliteration rule.
      #
      #   from       - source sequence to match (multi-character allowed)
      #   to         - replacement sequence (may be empty)
      #   priority   - integer priority used to disambiguate equal-length
      #                matches; higher wins (default 0)
      #   left       - string or Regexp the context immediately before the
      #                match must satisfy
      #   right      - string or Regexp the context immediately after the
      #                match must satisfy
      #   match_ascii - whether the rule may match pure ASCII sequences
      #
      # Rules are evaluated against the input normalized into a single,
      # explicit Unicode normalization form. The engine performs a single
      # left-to-right scan with longest valid match (then priority, then
      # definition order) and never feeds transliterated output back through
      # the rules.
      class Rule
        attr_reader :from, :to, :priority, :left, :right, :match_ascii

        def initialize(from:, to:, priority: 0, left: nil, right: nil, match_ascii: false)
          raise I18n::ArgumentError, "rule input (from) must be a non-empty String" unless from.is_a?(String) && !from.empty?
          raise I18n::ArgumentError, "rule output (to) must be a String" unless to.is_a?(String)
          unless left.nil? || left.is_a?(String) || left.is_a?(Regexp)
            raise I18n::ArgumentError, "left context must be a String or Regexp"
          end
          unless right.nil? || right.is_a?(String) || right.is_a?(Regexp)
            raise I18n::ArgumentError, "right context must be a String or Regexp"
          end
          @from = from
          @to = to
          @priority = priority
          @left = left
          @right = right
          @match_ascii = match_ascii
        end
      end

      # A transliterator which accepts a Proc as its transliteration rule.
      class ProcTransliterator
        def initialize(rule)
          @rule = rule
        end

        def transliterate(string, replacement = nil)
          @rule.call(string)
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

      # A transliterator driven by declarative Rule objects.
      #
      # Input is matched in an explicit Unicode normalization form (NFC by
      # default), with longest valid match taking precedence. Every emitted
      # output fragment carries the codepoint range it transliterated in the
      # original (pre-normalization) input. The default Latin => ASCII
      # approximations are inherited as lowest-priority single-character
      # rules and can be overridden by the given rules.
      class RuleTransliterator
        # Canonical Combining Class values are not exposed by Ruby's
        # standard library, so Mark characters plus Hangul medials/finals
        # (which compose with a preceding jamo) are treated as non-starters.
        # Splitting in front of every starter guarantees that normalizing
        # each chunk separately and joining the results is equivalent to
        # normalizing the whole string.
        NON_STARTER = /[\p{Mark}\u{1160}-\u{11A7}\u{11A8}-\u{11FF}]/u
        CHUNK = /#{NON_STARTER.source}*.?(?:#{NON_STARTER.source})*/um

        # Rules originating from the default approximation table.
        DEFAULT_PRIORITY = -1

        def initialize(rules = nil, normalization_form: :nfc)
          @normalization_form = normalization_form
          # @rule_buckets[first_char] holds multi-character rules whose
          # "from" begins with that codepoint, ordered longest match
          # first, then priority, then definition order.
          @rule_buckets = Hash.new { |hash, key| hash[key] = [] }
          # @char_buckets[first_char] holds single-character rules for
          # that codepoint, ordered by priority then definition order; the
          # first one whose contexts apply wins.
          @char_buckets = Hash.new { |hash, key| hash[key] = [] }
          @rule_order = 0
          HashTransliterator::DEFAULT_APPROXIMATIONS.each do |key, value|
            key = normalize(key)
            value = normalize(value)
            add_rule Rule.new(:from => key, :to => value, :priority => DEFAULT_PRIORITY)
          end
          import(rules)
        end

        def transliterate(string, replacement = nil)
          replacement ||= DEFAULT_REPLACEMENT_CHAR
          string = prepare_string(string)
          normalized = string.ascii_only? ? string : normalize(string)
          output = +""
          scan(normalized, replacement) do |fragment, _range|
            output << fragment
          end
          output
        end

        # Like #transliterate, but returns [output_fragment, original_range]
        # pairs. +original_range+ is a Range of codepoint indexes in the
        # unnormalized input that produced the fragment.
        def transliterate_with_ranges(string, replacement = nil)
          replacement ||= DEFAULT_REPLACEMENT_CHAR
          string = prepare_string(string)
          normalized, orig_starts, orig_ends, norm_starts, norm_ends = build_normalization_map(string)
          segments = []
          scan(normalized, replacement) do |fragment, range|
            segments << [fragment, range]
          end

          return [] if segments.empty?

          original_segments = segments.map do |output, norm_range|
            first_chunk = chunk_index_for(norm_range.begin, norm_starts, norm_ends)
            last_end = norm_range.exclude_end? ? norm_range.end - 1 : norm_range.end
            last_chunk = chunk_index_for(last_end, norm_starts, norm_ends)
            [output, orig_starts[first_chunk]...orig_ends[last_chunk]]
          end

          merge_overlapping(original_segments)
        end

        private

        def prepare_string(string)
          string = string.to_s
          unless string.valid_encoding?
            raise ArgumentError, "invalid byte sequence in #{string.encoding.name}"
          end
          string
        end

        # Single left-to-right scan over the normalized string, yielding
        # [output_fragment, normalized_range] pairs. Emitted output is
        # never revisited, so rules cannot cascade into one another.
        def scan(normalized, replacement)
          scan_state = Scan.new(normalized)
          pos = 0

          while pos < normalized.length
            char = normalized[pos]
            if (rule, length = find_multi_char_rule(scan_state, pos))
              yield rule.to, pos...(pos + length)
              pos += length
            elsif (rule = find_char_rule(scan_state, pos, char))
              yield rule.to, pos...(pos + 1)
              pos += 1
            elsif char.ascii_only? || replacement.equal?(:none)
              yield char, pos...(pos + 1)
              pos += 1
            else
              yield replacement, pos...(pos + 1)
              pos += 1
            end
          end
        end

        def import(rules)
          case rules
          when nil
          when Rule
            add_rule rules
          when Array
            rules.each do |rule|
              unless rule.is_a?(Rule)
                raise I18n::ArgumentError, "declarative transliteration rules must be I18n::Backend::Transliterator::Rule instances"
              end
              add_rule(rule)
            end
          when Hash
            rules.each do |key, value|
              if value.is_a?(Rule)
                add_rule value
              else
                key = normalize(key.to_s)
                value = normalize(value.to_s)
                add_rule Rule.new(:from => key, :to => value,
                                  :match_ascii => key.ascii_only?)
              end
            end
          else
            raise I18n::ArgumentError, "Transliteration rule must be a proc, a hash or declarative transliteration rules."
          end
        end

        def add_rule(rule)
          normalized_from = normalize(rule.from)
          normalized_to = normalize(rule.to)
          left = rule.left.is_a?(String) ? normalize(rule.left) : rule.left
          right = rule.right.is_a?(String) ? normalize(rule.right) : rule.right
          compiled = CompiledRule.new(rule, normalized_from, normalized_to, left, right, @rule_order)
          @rule_order += 1
          if normalized_from.length == 1
            bucket = @char_buckets[normalized_from]
            bucket << compiled
            # Same length: priority first, then definition order.
            bucket.sort_by! { |entry| [-entry.priority, entry.order] }
          else
            bucket = @rule_buckets[normalized_from.chars.first]
            bucket << compiled
            # Longest match first, then priority, then definition order.
            bucket.sort_by! { |entry| [-entry.from.length, -entry.priority, entry.order] }
          end
        end

        def normalize(string)
          case @normalization_form
          when :nfc then string.unicode_normalize(:nfc)
          when :nfd then string.unicode_normalize(:nfd)
          when :nfkc then string.unicode_normalize(:nfkc)
          when :nfkd then string.unicode_normalize(:nfkd)
          else
            raise I18n::ArgumentError, "unknown Unicode normalization form #{@normalization_form.inspect}"
          end
        rescue Encoding::CompatibilityError
          string
        end

        # Returns the normalized string and, for every normalization chunk,
        # both its codepoint range in the original input and in the
        # normalized string.
        #
        # For NFC/NFD the chunkwise result is guaranteed to be normalized
        # and aligns codepoints with the chunks. Compatibility forms
        # (:nfkc/:nfkd) can expand a single codepoint into several (e.g.
        # U+FB01 "ﬁ" => "fi"), so the joined chunks are normalized once
        # more; the chunk boundaries then act as conservative, possibly
        # coarser source ranges.
        def build_normalization_map(string)
          chunks = []
          string.scan(CHUNK) { chunks << Regexp.last_match(0) }

          normalized_parts = []
          orig_starts = []
          orig_ends = []
          norm_starts = []
          norm_ends = []
          orig_offset = 0
          norm_offset = 0
          chunks.each do |chunk|
            normalized_chunk = normalize(chunk)
            normalized_parts << normalized_chunk
            orig_starts << orig_offset
            norm_starts << norm_offset
            orig_offset += chunk.length
            norm_offset += normalized_chunk.length
            orig_ends << orig_offset
            norm_ends << norm_offset
          end

          normalized = normalize(normalized_parts.join)
          [normalized, orig_starts, orig_ends, norm_starts, norm_ends]
        end

        def chunk_index_for(norm_offset, norm_starts, norm_ends)
          index = norm_ends.bsearch_index { |end_offset| end_offset > norm_offset }
          index || norm_ends.length - 1
        end

        def find_multi_char_rule(scan, pos)
          bucket = @rule_buckets[scan.string[pos]]
          return nil unless bucket
          bucket.each do |rule|
            length = rule.from.length
            next if pos + length > scan.string.length
            next if rule.from.ascii_only? && !rule.match_ascii?
            next unless scan.byteslice(pos, length) == rule.from
            next unless contexts_match?(rule, scan, pos, length)
            return [rule, length]
          end
          nil
        end

        def find_char_rule(scan, pos, char)
          bucket = @char_buckets[char]
          return nil unless bucket
          bucket.each do |rule|
            next if rule.from.ascii_only? && !rule.match_ascii?
            return rule if contexts_match?(rule, scan, pos, 1)
          end
          nil
        end

        def contexts_match?(rule, scan, pos, length)
          left_context_match?(rule, scan, pos) &&
            right_context_match?(rule, scan, pos + length)
        end

        def left_context_match?(rule, scan, pos)
          context = rule.left
          return true if context.nil?
          if context.is_a?(String)
            scan.prefix(pos).end_with?(context)
          else
            # Anchor the pattern so its end coincides with the match start.
            # The lookahead reaches the string end, letting zero-width
            # assertions such as \b inspect the character right of the
            # boundary and making the pattern end exactly at the boundary.
            regexp = Regexp.new('\A.*(?:' + context.source +
              ')(?=' + Regexp.escape(rule.from) + '\z)', context.options | Regexp::MULTILINE)
            regexp.match?(scan.prefix(pos) + rule.from)
          end
        end

        def right_context_match?(rule, scan, pos)
          context = rule.right
          return true if context.nil?
          if context.is_a?(String)
            scan.suffix(pos).start_with?(context)
          else
            # Anchor the pattern at the match end; the matched text is
            # prepended so boundary assertions (\b) can inspect the
            # character left of the boundary.
            regexp = Regexp.new('\A(?:' + Regexp.escape(rule.from) +
              ')(?:' + context.source + ')', context.options | Regexp::MULTILINE)
            regexp.match?(rule.from + scan.suffix(pos))
          end
        end

        # Merge consecutive fragments whose original ranges overlap (this can
        # happen when a multi-codepoint sequence composes into one code point
        # and is emitted piece by piece).
        def merge_overlapping(segments)
          merged = []
          segments.each do |output, range|
            if merged.any? && range.begin < merged.last[1].end
              previous_output, previous_range = merged.last
              merged[-1] = [previous_output + output, previous_range.begin...[previous_range.end, range.end].max]
            else
              merged << [output, range]
            end
          end
          merged
        end

        # A rule with pre-normalized strings and precomputed context regexps.
        class CompiledRule
          attr_reader :from, :to, :priority, :order

          def initialize(rule, from, to, left, right, order)
            @rule = rule
            @from = from
            @to = to
            @priority = rule.priority
            @left = left
            @right = right
            @order = order
          end

          def match_ascii?
            @rule.match_ascii
          end

          def left
            @left
          end

          def right
            @right
          end
        end

        # Per-transliteration scan state: converts codepoint indexes into
        # byte offsets without allocating an array of characters.
        class Scan
          attr_reader :string

          def initialize(string)
            @string = string
            @byte_offsets = [0]
          end

          def byteslice(char_pos, char_length)
            start_byte = byte_offset(char_pos)
            end_byte = byte_offset(char_pos + char_length)
            @string.byteslice(start_byte, end_byte - start_byte)
          end

          def prefix(char_pos)
            @string.byteslice(0, byte_offset(char_pos))
          end

          def suffix(char_pos)
            byte_pos = byte_offset(char_pos)
            @string.byteslice(byte_pos, @string.bytesize - byte_pos)
          end

          private

          def byte_offset(char_pos)
            while @byte_offsets.length <= char_pos
              char = @string[@byte_offsets.length - 1]
              @byte_offsets << @byte_offsets.last + char.bytesize
            end
            @byte_offsets[char_pos]
          end
        end
      end
    end
  end
end
