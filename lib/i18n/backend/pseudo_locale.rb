# frozen_string_literal: true

require 'i18n/pseudo_localizer'

module I18n
  module Backend
    # Backend mixin that serves pseudo-localized translations for the locales
    # configured via I18n.config.pseudo_locales.
    #
    # For a pseudo locale the translation is resolved from the source locale
    # (I18n.config.pseudo_source_locale, defaulting to the default locale),
    # pluralized through the normal pluralization flow, pseudo-localized and
    # only then interpolated - so interpolated user values are never expanded
    # or rewritten. All other locales are served untouched.
    #
    #   I18n.backend = I18n::Backend::Simple.new
    #   I18n.backend.extend(I18n::Backend::PseudoLocale)
    #   I18n.config.pseudo_locales = [:ps]
    #   I18n.available_locales = [:en, :ps]
    #
    #   I18n.t('inbox.messages', :locale => :ps, :count => 2)
    module PseudoLocale
      def translate(locale, key, options = EMPTY_HASH)
        return super unless I18n.pseudo_locale?(locale)

        source_locale = I18n.pseudo_source_locale
        values = options.empty? ? nil : Utils.except(options, *RESERVED_KEYS)
        interpolate_values = values && !values.empty? && !options[:skip_interpolation]

        # Resolve and pluralize the source template without interpolating so
        # that only the template itself is pseudo-localized.
        entry = if interpolate_values
          super(source_locale, key, options.merge(:skip_interpolation => true))
        else
          super(source_locale, key, options)
        end

        entry = I18n.pseudo_localize(entry)

        if interpolate_values
          if options[:deep_interpolation]
            deep_interpolate(source_locale, entry, values)
          else
            interpolate(source_locale, entry, values)
          end
        else
          entry
        end
      end

      def exists?(locale, key, options = EMPTY_HASH)
        locale = I18n.pseudo_source_locale if I18n.pseudo_locale?(locale)
        super
      end
    end
  end
end
