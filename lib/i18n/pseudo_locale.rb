# frozen_string_literal: true

module I18n
  # Pseudo-localization support.
  #
  # Pseudo-localization expands and transforms source-language text so that
  # layout/length overflow problems in server-rendered pages and emails can be
  # spotted before the real translations are delivered.
  #
  # The transformer:
  #
  # * replaces Latin letters with accented look-alikes,
  # * deterministically expands text by a configurable ratio,
  # * wraps the result in configurable left/right markers,
  # * preserves interpolation placeholders (%{name}, %<name>d), escaped
  #   percents (%%), HTML tags, HTML entities, URLs, email addresses and
  #   business-ID-like tokens (e.g. UUIDs, ORD-12345),
  # * keeps unsupported format fragments (e.g. bare %s / %d) untouched and
  #   records a queryable hint for each of them.
  #
  # Pluralization and interpolation are still performed by the normal I18n
  # flow (see I18n::Backend::PseudoLocale), so values interpolated into the
  # message are never expanded or rewritten.
  #
  # Usage:
  #
  #   I18n::PseudoLocale.configure do |config|
  #     config.locales = [:ps]
  #     config.expansion_ratio = 1.4
  #     config.left_marker = '[[['
  #     config.right_marker = ']]]'
  #   end
  #
  #   I18n::Backend::Simple.include(I18n::Backend::PseudoLocale)
  module PseudoLocale
    # Default one-to-one letter substitution map. Deterministic by design.
    DEFAULT_CHARACTER_MAP = {
      'a' => 'à', 'b' => 'ƀ', 'c' => 'ç', 'd' => 'ð', 'e' => 'ë',
      'f' => 'ƒ', 'g' => 'ğ', 'h' => 'ħ', 'i' => 'ï', 'j' => 'ĵ',
      'k' => 'ķ', 'l' => 'ľ', 'm' => 'ɱ', 'n' => 'ñ', 'o' => 'ö',
      'p' => 'þ', 'q' => 'ǫ', 'r' => 'ŕ', 's' => 'š', 't' => 'ţ',
      'u' => 'ü', 'v' => 'ṽ', 'w' => 'ŵ', 'x' => 'ẋ', 'y' => 'ÿ',
      'z' => 'ž',
      'A' => 'À', 'B' => 'Ɓ', 'C' => 'Ç', 'D' => 'Ð', 'E' => 'Ë',
      'F' => 'Ƒ', 'G' => 'Ğ', 'H' => 'Ħ', 'I' => 'Ï', 'J' => 'Ĵ',
      'K' => 'Ķ', 'L' => 'Ľ', 'M' => 'Ṁ', 'N' => 'Ñ', 'O' => 'Ö',
      'P' => 'Þ', 'Q' => 'Ǫ', 'R' => 'Ŕ', 'S' => 'Š', 'T' => 'Ţ',
      'U' => 'Ü', 'V' => 'Ṽ', 'W' => 'Ŵ', 'X' => 'Ẋ', 'Y' => 'Ÿ',
      'Z' => 'Ž'
    }.freeze

    # Characters used to pad words during expansion.
    DEFAULT_EXPANSION_POOL = %w[à â ã å ç è ê ë ì î ñ ò ô õ ø ù û ü ý].freeze

    # A hint recorded when the transformer meets a format fragment it does
    # not support. Hints are queryable through I18n::PseudoLocale.hints.
    Hint = Struct.new(:fragment, :string, :reason)

    class Configuration
      # Locales (symbols) for which pseudo-localization is applied.
      attr_accessor :locales
      # Deterministic expansion ratio applied to source text (1.0 = no
      # expansion, 1.4 = roughly 40% longer).
      attr_accessor :expansion_ratio
      # Markers wrapped around every pseudo-localized string.
      attr_accessor :left_marker, :right_marker
      # Letter substitution map.
      attr_accessor :character_map
      # Pool of characters used for deterministic expansion padding.
      attr_accessor :expansion_pool
      # Additional user-supplied regexps for tokens that must be preserved
      # verbatim (e.g. project-specific business ID formats).
      attr_accessor :protected_patterns

      def initialize
        @locales = []
        @expansion_ratio = 1.4
        @left_marker = '⟦'
        @right_marker = '⟧'
        @character_map = DEFAULT_CHARACTER_MAP.dup
        @expansion_pool = DEFAULT_EXPANSION_POOL.dup
        @protected_patterns = []
      end

      def enabled_for?(locale)
        !locale.nil? && locales.any? { |l| l.to_sym == locale.to_sym }
      end
    end

    class << self
      def configure
        yield configuration
        configuration
      end

      def configuration
        @configuration ||= Configuration.new
      end

      def configuration=(config)
        @configuration = config
      end

      def enabled_for?(locale)
        configuration.enabled_for?(locale)
      end

      # Transforms a single source string. Deterministic: the same input and
      # configuration always produce the same output.
      def transform(string)
        Transformer.new(configuration).transform(string)
      end

      # All hints recorded so far (unsupported format fragments that were
      # preserved verbatim).
      def hints
        hints_mutex.synchronize { @hints ||= [] }
      end

      def record_hint(fragment, string, reason)
        hints_mutex.synchronize { (@hints ||= []) << Hint.new(fragment, string, reason) }
        nil
      end

      def clear_hints
        hints_mutex.synchronize { @hints = [] }
      end

      # Resets configuration and hints. Mostly useful for tests.
      def reset!
        @configuration = Configuration.new
        clear_hints
      end

      private

      def hints_mutex
        @hints_mutex ||= Mutex.new
      end
    end

    # Performs the actual string transformation. Instances are cheap and
    # hold no mutable state beyond the configuration they were given.
    class Transformer
      # Named interpolation placeholders: %{name} or %{name|word}
      INTERPOLATION = /%\{[\w|]+\}/
      # Named sprintf placeholders: %<name>d, %<price>.2f, ...
      SPRINTF_NAMED = /%<\w+>[^\d]*?\d*\.?\d*[bBdiouxXeEfgGcps]/
      # Escaped percent.
      ESCAPED_PERCENT = /%%/
      # Positional/unnamed sprintf fragments we do not rewrite but flag:
      # %s, %d, %.2f, %1$s, ...
      SPRINTF_UNSUPPORTED = /%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?[bcdeEfgGiopsuxX]/
      # HTML entities: &amp; &#123; &#x1F;
      ENTITY = /&(?:[a-zA-Z][a-zA-Z0-9]+|#[0-9]+|#x[0-9a-fA-F]+);/
      # HTML tags (attributes, and therefore link targets, stay untouched).
      TAG = %r{</?[a-zA-Z][^>]*?>}
      # Bare URLs.
      URL = %r{(?:https?|ftp)://[^\s<>"']+|www\.[^\s<>"']+}i
      # Email addresses.
      EMAIL = /[\w.+-]+@[\w-]+(?:\.[\w-]+)+/
      # UUIDs.
      UUID = /\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/
      # Hyphenated alphanumeric tokens containing at least one digit and one
      # letter, e.g. business IDs like ORD-12345 or SKU-9X-2016.
      BUSINESS_ID = /\b(?=[A-Za-z0-9-]*\d)(?=[A-Za-z0-9-]*[A-Za-z])[A-Za-z0-9]+(?:-[A-Za-z0-9]+)+\b/

      WORD = /[A-Za-z]+/

      attr_reader :config

      def initialize(config = PseudoLocale.configuration)
        @config = config
        @token_pattern = build_token_pattern(config.protected_patterns)
      end

      def transform(string)
        return string if string.empty?

        transformed = +''

        each_segment(string) do |kind, segment|
          case kind
          when :text
            transformed << transform_text(segment)
          when :unsupported
            PseudoLocale.record_hint(segment, string, 'unsupported format fragment preserved verbatim')
            transformed << segment
          else # :protected
            transformed << segment
          end
        end

        "#{config.left_marker}#{transformed}#{config.right_marker}"
      end

      private

      def build_token_pattern(extra_patterns)
        patterns = [
          [INTERPOLATION, :protected],
          [SPRINTF_NAMED, :protected],
          [ESCAPED_PERCENT, :protected],
          [SPRINTF_UNSUPPORTED, :unsupported],
          [ENTITY, :protected],
          [TAG, :protected],
          [URL, :protected],
          [EMAIL, :protected],
          [UUID, :protected],
          [BUSINESS_ID, :protected]
        ]
        extra_patterns.each { |pattern| patterns << [pattern, :protected] }

        # Order matters: earlier alternatives win.
        combined = Regexp.union(patterns.map(&:first))
        [combined, patterns]
      end

      # Yields (:text | :protected | :unsupported, segment) for the whole
      # string, in order.
      def each_segment(string)
        combined, patterns = @token_pattern
        offset = 0

        string.scan(combined) do
          match = Regexp.last_match
          if match.begin(0) > offset
            yield :text, string[offset...match.begin(0)]
          end
          token = match[0]
          kind = patterns.find { |pattern, _| token.match?(/\A(?:#{pattern})\z/) }&.last || :protected
          yield kind, token
          offset = match.end(0)
        end

        yield :text, string[offset..] if offset < string.length
      end

      # Substitutes letters and deterministically pads words so the segment
      # grows towards config.expansion_ratio. A fractional carry is kept
      # across words so the overall ratio stays close to the configured one
      # while remaining fully deterministic.
      def transform_text(segment)
        carry = 0.0
        ratio = config.expansion_ratio.to_f

        segment.gsub(WORD) do |word|
          substituted = substitute(word)
          target = word.length * ratio + carry
          padding = target.floor - word.length
          carry = target - target.floor
          padding > 0 ? substituted + padding_for(word, padding) : substituted
        end
      end

      def substitute(word)
        map = config.character_map
        word.each_char.map { |char| map[char] || char }.join
      end

      # Deterministic padding derived from the word itself: the same word
      # always receives the same padding characters, so repeated runs over
      # the same templates produce identical output.
      def padding_for(word, count)
        pool = config.expansion_pool
        return '' if pool.empty?

        seed = word.sum
        (0...count).map { |i| pool[(seed + i) % pool.size] }.join
      end
    end
  end
end
