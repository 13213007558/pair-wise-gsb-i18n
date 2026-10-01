# frozen_string_literal: true

require 'strscan'

module I18n
  # Pseudo-localizes translation templates so that server-rendered pages and
  # emails can be checked for length overflow, encoding issues and hard-coded
  # strings before real translations are available.
  #
  # The transformation is fully deterministic: the same template always
  # produces the same pseudo-localized output. Interpolation placeholders
  # (%{name}, %<name>fmt, %%), HTML tags, HTML entities, URLs, email
  # addresses and business identifiers are preserved as-is, so pluralization
  # and interpolation keep working through the normal I18n flow and links or
  # IDs are never rewritten. Format fragments that are not understood (e.g.
  # bare %d) are kept verbatim and reported through
  # I18n::PseudoLocalizer.unsupported_fragments.
  module PseudoLocalizer
    # Fraction of the source text length that is added as deterministic
    # padding. 0.35 grows "Hello" (5 chars) by 2 characters.
    DEFAULT_EXPANSION_RATIO = 0.35

    # Left and right markers wrapped around every pseudo-localized string.
    DEFAULT_MARKERS = ["⟦", "⟧"].freeze

    # Default character substitutions giving text a distinct, accented look.
    DEFAULT_CHARACTER_MAP = {
      "a" => "à", "b" => "ƀ", "c" => "ç", "d" => "ð", "e" => "ë",
      "f" => "ƒ", "g" => "ğ", "h" => "ħ", "i" => "ï", "j" => "ĵ",
      "k" => "ķ", "l" => "ļ", "m" => "ɱ", "n" => "ñ", "o" => "ö",
      "p" => "þ", "q" => "ǫ", "r" => "ŕ", "s" => "š", "t" => "ţ",
      "u" => "ü", "v" => "ṽ", "w" => "ŵ", "x" => "ẋ", "y" => "ÿ",
      "z" => "ž",
      "A" => "À", "B" => "Ɓ", "C" => "Ç", "D" => "Ð", "E" => "Ë",
      "F" => "Ƒ", "G" => "Ğ", "H" => "Ħ", "I" => "Ï", "J" => "Ĵ",
      "K" => "Ķ", "L" => "Ļ", "M" => "Ṁ", "N" => "Ñ", "O" => "Ö",
      "P" => "Þ", "Q" => "Ǫ", "R" => "Ŕ", "S" => "Š", "T" => "Ţ",
      "U" => "Ü", "V" => "Ṽ", "W" => "Ŵ", "X" => "Ẋ", "Y" => "Ÿ",
      "Z" => "Ž"
    }.freeze

    # Deterministic padding cycled to expand text.
    EXPANSION_FILLER = "àçèñţš".freeze

    # Patterns that are always kept verbatim: interpolation placeholders,
    # escaped percents, HTML entities, HTML comments/tags, URLs and emails.
    BASE_PROTECTED_PATTERNS = [
      /%%\{[^}]*\}/,                                            # escaped placeholder %%{name}
      /%%/,                                                     # escaped percent
      /%\{[^}]+\}/,                                             # %{name} / %{name|word}
      /%<\w+>[-+0 #]*\d*(?:\.\d+)?[bBdiouxXeEfgGcps]/,          # %<name>fmt
      /&(?:#[0-9]+|#x[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);/,      # HTML entities
      /<!--.*?-->/m,                                            # HTML comments
      %r{</?[a-zA-Z][^>]*>},                                    # HTML tags
      %r{(?:https?|ftp)://[^\s<>"'\])]+},                       # URLs
      /mailto:[^\s<>"'\]]+/,                                    # mailto: links
      /[\w.+-]+@[\w-]+(?:\.[\w-]+)+/                            # email addresses
    ].freeze

    # Default patterns for business identifiers (e.g. ORD-12345, ABC123)
    # that must never be rewritten.
    DEFAULT_PRESERVE_PATTERNS = [
      /\b(?=[A-Z0-9_-]*\d)(?=[A-Z0-9_-]*[A-Z])[A-Z0-9](?:[A-Z0-9_-]*[A-Z0-9])?\b/
    ].freeze

    # sprintf-style fragments we do not understand. They are kept as-is and
    # reported through .unsupported_fragments.
    UNSUPPORTED_FORMAT_PATTERN = /%(?:\d+\$)?[-+0 #]*\d*(?:\.\d+)?[a-zA-Z]/

    MAX_UNSUPPORTED_FRAGMENTS = 1000

    class << self
      # Pseudo-localizes the given entry. Strings are transformed, Arrays and
      # Hashes are traversed recursively (hash keys are kept untouched),
      # anything else is returned unchanged.
      def pseudo_localize(entry, config = I18n.config)
        case entry
        when ::String
          transform_string(entry, config)
        when ::Array
          entry.map { |element| pseudo_localize(element, config) }
        when ::Hash
          entry.each_with_object({}) do |(key, value), result|
            result[key] = pseudo_localize(value, config)
          end
        else
          entry
        end
      end

      # Returns the list of unsupported format fragments encountered so far.
      # Each entry is a Hash with :fragment and :template keys.
      def unsupported_fragments
        unsupported_registry.synchronize { @unsupported_fragments.map(&:dup) }
      end

      # Clears the list of unsupported format fragments.
      def clear_unsupported_fragments
        unsupported_registry.synchronize { @unsupported_fragments.clear }
        nil
      end

      private

      def transform_string(string, config)
        return string if string.empty?

        character_map = config.pseudo_character_map || DEFAULT_CHARACTER_MAP
        ratio = config.pseudo_expansion_ratio || DEFAULT_EXPANSION_RATIO
        left, right = (config.pseudo_markers || DEFAULT_MARKERS)

        parts = tokenize(string, protected_pattern(config)).map do |type, text|
          case type
          when :protected
            text
          when :unsupported
            record_unsupported(text, string)
            text
          else
            expand(replace_characters(text, character_map), ratio)
          end
        end

        "#{left}#{parts.join}#{right}"
      end

      def tokenize(string, protected_pattern)
        tokens = []
        scanner = StringScanner.new(string)
        text = +""

        until scanner.eos?
          if (token = scanner.scan(protected_pattern))
            tokens << [:text, text] unless text.empty?
            text = +""
            tokens << [:protected, token]
          elsif (token = scanner.scan(UNSUPPORTED_FORMAT_PATTERN))
            tokens << [:text, text] unless text.empty?
            text = +""
            tokens << [:unsupported, token]
          else
            text << scanner.getch
          end
        end
        tokens << [:text, text] unless text.empty?
        tokens
      end

      def protected_pattern(config)
        patterns = BASE_PROTECTED_PATTERNS + Array(config.pseudo_preserve_patterns)
        pattern_cache[patterns] ||= Regexp.union(patterns)
      end

      def pattern_cache
        @pattern_cache ||= Concurrent::Map.new
      end

      def replace_characters(text, character_map)
        text.gsub(/[[:alpha:]]/) { |char| character_map[char] || char }
      end

      # Appends deterministic padding so the text grows by the configured
      # ratio. Padding is inserted before trailing whitespace so following
      # markup or placeholders stay attached to real text.
      def expand(text, ratio)
        return text if ratio.to_f <= 0 || text !~ /[[:alpha:]]/

        extra = (text.length * ratio).ceil
        return text if extra <= 0

        padding = EXPANSION_FILLER * ((extra.to_f / EXPANSION_FILLER.length).ceil)
        padding = padding[0, extra]

        if text =~ /\s+\z/
          text.sub(/(\s+)\z/) { padding + Regexp.last_match(1) }
        else
          text + padding
        end
      end

      def record_unsupported(fragment, template)
        entry = { :fragment => fragment, :template => template }.freeze
        unsupported_registry.synchronize do
          unless @unsupported_fragments.include?(entry) ||
                 @unsupported_fragments.size >= MAX_UNSUPPORTED_FRAGMENTS
            @unsupported_fragments << entry
          end
        end
        entry
      end

      def unsupported_registry
        @unsupported_registry ||= begin
          @unsupported_fragments = []
          Mutex.new
        end
      end
    end
  end

  class << self
    # Returns true if the given locale is configured as a pseudo locale.
    def pseudo_locale?(locale)
      !locale.nil? && locale != false && config.pseudo_locales.include?(locale.to_sym)
    end

    # Returns the locale pseudo-localized templates are sourced from.
    # Defaults to the default locale.
    def pseudo_source_locale
      config.pseudo_source_locale || config.default_locale
    end

    # Pseudo-localizes a translation entry. See I18n::PseudoLocalizer.
    def pseudo_localize(entry)
      PseudoLocalizer.pseudo_localize(entry)
    end
  end
end
