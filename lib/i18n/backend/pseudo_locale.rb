# frozen_string_literal: true

require 'i18n/pseudo_locale'

module I18n
  module Backend
    # Backend module that serves pseudo-localized strings for the locales
    # configured in I18n::PseudoLocale.
    #
    # The transformation happens at lookup time, i.e. on the stored
    # translation template *before* pluralization and interpolation run
    # through the normal I18n flow. As a result, interpolated user values
    # (names, counts, links built at runtime, ...) are never expanded or
    # rewritten.
    #
    # When a pseudo locale has no translation of its own for a key, the
    # source text is looked up in the default locale and transformed, so
    # pages and emails can be checked for length overflow before the real
    # translations are delivered.
    #
    #   I18n::Backend::Simple.include(I18n::Backend::PseudoLocale)
    #
    #   I18n::PseudoLocale.configure do |config|
    #     config.locales = [:ps]
    #   end
    module PseudoLocale
      protected

      def lookup(locale, key, scope = [], options = EMPTY_HASH)
        return super unless ::I18n::PseudoLocale.enabled_for?(locale)

        entry = super
        if entry.nil? && !default_locale?(locale)
          entry = super(default_locale_for_pseudo, key, scope, options)
        end
        pseudo_localize_entry(entry)
      end

      private

      def pseudo_localize_entry(entry)
        case entry
        when String
          ::I18n::PseudoLocale.transform(entry)
        when Hash
          entry.each_with_object({}) do |(key, value), result|
            result[key] = pseudo_localize_entry(value)
          end
        when Array
          entry.map { |value| pseudo_localize_entry(value) }
        else
          entry
        end
      end

      def default_locale?(locale)
        locale.to_sym == ::I18n.default_locale.to_sym
      end

      def default_locale_for_pseudo
        ::I18n.default_locale
      end
    end
  end
end
