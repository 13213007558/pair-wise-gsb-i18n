# frozen_string_literal: true

require 'set'

module I18n
  class Config
    # The only configuration value that is not global and scoped to thread is :locale.
    # It defaults to the default_locale.
    def locale
      defined?(@locale) && @locale != nil ? @locale : default_locale
    end

    def initialize
      @owner = Fiber.current
    end

    def owned_by?(fiber)
      @owner == fiber
    end

    def owner=(fiber)
      @owner = fiber
    end

    def initialize_copy(other)
      @owner = Fiber.current
    end

    # Returns a copied configuration with the provided attributes set.
    def with(**attrs)
      dup.tap do |copy|
        attrs.each do |name, value|
          copy.public_send("#{name}=", value)
        end
      end
    end

    # Sets this configuration as the current one for the active execution context.
    # The stored configuration is frozen to avoid sharing mutable state between fibers.
    def set!
      self.owner = Fiber.current unless frozen?
      freeze
      I18n.config = self
      self
    end

    # Sets the current locale pseudo-globally, i.e. in the Thread.current or Fiber local hash.
    def locale=(locale)
      I18n.enforce_available_locales!(locale)
      @locale = locale && locale.to_sym
    end

    # Returns the current backend. Defaults to +Backend::Simple+.
    def backend
      @@backend ||= Backend::Simple.new
    end

    # Sets the current backend. Used to set a custom backend.
    def backend=(backend)
      @@backend = backend
    end

    # Returns the current default locale. Defaults to :'en'
    def default_locale
      @@default_locale ||= :en
    end

    # Sets the current default locale. Used to set a custom default locale.
    def default_locale=(locale)
      I18n.enforce_available_locales!(locale)
      @@default_locale = locale && locale.to_sym
    end

    # Returns an array of locales for which translations are available.
    # Unless you explicitly set these through I18n.available_locales=
    # the call will be delegated to the backend.
    def available_locales
      @@available_locales ||= nil
      @@available_locales || backend.available_locales
    end

    # Caches the available locales list as both strings and symbols in a Set, so
    # that we can have faster lookups to do the available locales enforce check.
    def available_locales_set #:nodoc:
      @@available_locales_set ||= available_locales.inject(Set.new) do |set, locale|
        set << locale.to_s << locale.to_sym
      end
    end

    # Sets the available locales.
    def available_locales=(locales)
      @@available_locales = Array(locales).map { |locale| locale.to_sym }
      @@available_locales = nil if @@available_locales.empty?
      @@available_locales_set = nil
    end

    # Returns true if the available_locales have been initialized
    def available_locales_initialized?
      ( !!defined?(@@available_locales) && !!@@available_locales )
    end

    # Clears the available locales set so it can be recomputed again after I18n
    # gets reloaded.
    def clear_available_locales_set #:nodoc:
      @@available_locales_set = nil
    end

    # Returns the current default scope separator. Defaults to '.'
    def default_separator
      @@default_separator ||= '.'
    end

    # Sets the current default scope separator.
    def default_separator=(separator)
      @@default_separator = separator
    end

    # Returns the current exception handler. Defaults to an instance of
    # I18n::ExceptionHandler.
    def exception_handler
      @@exception_handler ||= ExceptionHandler.new
    end

    # Sets the exception handler.
    def exception_handler=(exception_handler)
      @@exception_handler = exception_handler
    end

    # Returns the current handler for situations when interpolation argument
    # is missing. MissingInterpolationArgument will be raised by default.
    def missing_interpolation_argument_handler
      @@missing_interpolation_argument_handler ||= lambda do |missing_key, provided_hash, string|
        raise MissingInterpolationArgument.new(missing_key, provided_hash, string)
      end
    end

    # Sets the missing interpolation argument handler. It can be any
    # object that responds to #call. The arguments that will be passed to #call
    # are the same as for MissingInterpolationArgument initializer. Use +Proc.new+
    # if you don't care about arity.
    #
    # == Example:
    # You can suppress raising an exception and return string instead:
    #
    #   I18n.config.missing_interpolation_argument_handler = Proc.new do |key|
    #     "#{key} is missing"
    #   end
    def missing_interpolation_argument_handler=(exception_handler)
      @@missing_interpolation_argument_handler = exception_handler
    end

    # Allow clients to register paths providing translation data sources. The
    # backend defines acceptable sources.
    #
    # E.g. the provided SimpleBackend accepts a list of paths to translation
    # files which are either named *.rb and contain plain Ruby Hashes or are
    # named *.yml and contain YAML data. So for the SimpleBackend clients may
    # register translation files like this:
    #   I18n.load_path << 'path/to/locale/en.yml'
    def load_path
      @@load_path ||= []
    end

    # Sets the load path instance. Custom implementations are expected to
    # behave like a Ruby Array.
    def load_path=(load_path)
      @@load_path = load_path
      @@available_locales_set = nil
      backend.reload!
    end

    # Whether or not to verify if locales are in the list of available locales.
    # Defaults to true.
    @@enforce_available_locales = true
    def enforce_available_locales
      @@enforce_available_locales
    end

    def enforce_available_locales=(enforce_available_locales)
      @@enforce_available_locales = enforce_available_locales
    end

    # Returns the current interpolation patterns. Defaults to
    # I18n::DEFAULT_INTERPOLATION_PATTERNS.
    def interpolation_patterns
      @@interpolation_patterns ||= I18n::DEFAULT_INTERPOLATION_PATTERNS.dup
    end

    # Sets the current interpolation patterns. Used to set a interpolation
    # patterns.
    #
    # E.g. using {{}} as a placeholder like "{{hello}}, world!":
    #
    #   I18n.config.interpolation_patterns << /\{\{(\w+)\}\}/
    def interpolation_patterns=(interpolation_patterns)
      @@interpolation_patterns = interpolation_patterns
    end

    # Returns the locales that are treated as pseudo locales. Defaults to [].
    # See I18n::Backend::PseudoLocale.
    def pseudo_locales
      @@pseudo_locales ||= []
    end

    # Sets the locales that are served pseudo-localized translations.
    def pseudo_locales=(locales)
      @@pseudo_locales = Array(locales).compact.map { |locale| locale.to_sym }
    end

    # Returns the locale pseudo-localized templates are sourced from.
    # Defaults to nil, which means the default locale is used.
    def pseudo_source_locale
      @@pseudo_source_locale ||= nil
    end

    # Sets the source locale for pseudo-localized translations.
    def pseudo_source_locale=(locale)
      @@pseudo_source_locale = locale && locale.to_sym
    end

    # Returns the deterministic expansion ratio used to grow pseudo-localized
    # text. Defaults to I18n::PseudoLocalizer::DEFAULT_EXPANSION_RATIO.
    def pseudo_expansion_ratio
      @@pseudo_expansion_ratio ||= PseudoLocalizer::DEFAULT_EXPANSION_RATIO
    end

    # Sets the expansion ratio for pseudo-localized text. Set to 0 to disable
    # expansion.
    def pseudo_expansion_ratio=(ratio)
      @@pseudo_expansion_ratio = ratio && ratio.to_f
    end

    # Returns the left and right markers wrapped around pseudo-localized
    # strings. Defaults to I18n::PseudoLocalizer::DEFAULT_MARKERS.
    def pseudo_markers
      @@pseudo_markers ||= PseudoLocalizer::DEFAULT_MARKERS
    end

    # Sets the left and right markers for pseudo-localized strings. Accepts a
    # pair of strings, e.g. I18n.config.pseudo_markers = ["[", "]"]. Use
    # ["", ""] to disable markers.
    def pseudo_markers=(markers)
      if markers.nil?
        @@pseudo_markers = nil
        return
      end
      markers = Array(markers)
      unless markers.size == 2
        raise ArgumentError, "pseudo_markers must be a pair of [left, right] strings"
      end
      @@pseudo_markers = markers.map { |marker| marker.to_s }
    end

    # Returns the character substitution map used for pseudo-localization.
    # Defaults to I18n::PseudoLocalizer::DEFAULT_CHARACTER_MAP.
    def pseudo_character_map
      @@pseudo_character_map ||= PseudoLocalizer::DEFAULT_CHARACTER_MAP
    end

    # Sets the character substitution map used for pseudo-localization.
    def pseudo_character_map=(map)
      @@pseudo_character_map = map
    end

    # Returns the patterns for tokens (e.g. business IDs) that must be kept
    # verbatim during pseudo-localization. Defaults to
    # I18n::PseudoLocalizer::DEFAULT_PRESERVE_PATTERNS.
    def pseudo_preserve_patterns
      @@pseudo_preserve_patterns ||= PseudoLocalizer::DEFAULT_PRESERVE_PATTERNS
    end

    # Sets the patterns for tokens that must be kept verbatim during
    # pseudo-localization. This replaces the defaults; include
    # I18n::PseudoLocalizer::DEFAULT_PRESERVE_PATTERNS to keep them.
    def pseudo_preserve_patterns=(patterns)
      @@pseudo_preserve_patterns = patterns && Array(patterns)
    end
  end
end
