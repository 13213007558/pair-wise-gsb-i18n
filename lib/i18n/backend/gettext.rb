# frozen_string_literal: true

require 'i18n/gettext'
require 'i18n/gettext/po_parser'

module I18n
  module Backend
    # Experimental support for using Gettext po files to store translations.
    #
    # To use this you can simply include the module to the Simple backend - or
    # whatever other backend you are using.
    #
    #  I18n::Backend::Simple.include(I18n::Backend::Gettext)
    #
    # Now you should be able to include your Gettext translation (*.po) files to
    # the +I18n.load_path+ so they're loaded to the backend and you can use them as
    # usual:
    #
    #  I18n.load_path += Dir["path/to/locales/*.po"]
    #
    # Following the Gettext convention this implementation expects that your
    # translation files are named by their locales. E.g. the file en.po would
    # contain the translations for the English locale.
    #
    # To translate text <b>you must use</b> one of the translate methods provided by
    # I18n::Gettext::Helpers.
    #
    #  include I18n::Gettext::Helpers
    #  puts _("some string")
    #
    # Without it strings containing periods (".") will not be translated.
    #
    # When a PO file declares a +Plural-Forms+ header (nplurals and a plural
    # expression), the rule is parsed safely (no Ruby code is evaluated) and
    # used to pick the msgstr index for a given count. Files without such a
    # header fall back to the preset I18n::Gettext.plural_keys. If several PO
    # files for the same locale declare conflicting rules an error is raised
    # by default; see I18n::Gettext.plural_forms_conflict_strategy= for other
    # strategies.

    module Gettext
      class PoData < Hash
        def set_comment(msgid_or_sym, comment)
          # ignore
        end
      end

      # Reset translations and any Plural-Forms rules collected from PO files.
      def reload!
        @gettext_plural_forms = nil
        super
      end

      protected
        def load_po(filename)
          locale = ::File.basename(filename, '.po').to_sym
          data = parse(filename)
          register_plural_forms(locale, extract_plural_forms(data, filename))
          data = normalize(locale, data, filename)
          [{ locale => data }, false]
        end

        def parse(filename)
          GetText::PoParser.new.parse(::File.read(filename), PoData.new)
        end

        # Reads the Plural-Forms entry from the PO file header (the msgstr of
        # the empty msgid), if any. Returns an I18n::Gettext::PluralForms
        # instance or nil when the file does not declare one.
        def extract_plural_forms(data, filename)
          header = data['']
          return nil unless header.is_a?(String) && header =~ /^Plural-Forms:[ \t]*(.*?)[ \t]*$/

          I18n::Gettext::PluralForms.parse($1, filename)
        end

        # Remembers the Plural-Forms rule declared by a PO file. When two
        # files for the same locale declare different rules the behaviour is
        # controlled by I18n::Gettext.plural_forms_conflict_strategy and
        # defaults to raising an error - the last file never wins silently.
        def register_plural_forms(locale, plural_forms)
          return unless plural_forms

          existing = gettext_plural_forms[locale]
          if existing && existing != plural_forms
            case I18n::Gettext.plural_forms_conflict_strategy
            when :first
              return
            when :raise
              raise I18n::Gettext::PluralForms::ConflictingRules,
                "conflicting Plural-Forms rules for locale #{locale}: " \
                "#{existing.expression.inspect} (nplurals=#{existing.nplurals}, from #{existing.location}) vs " \
                "#{plural_forms.expression.inspect} (nplurals=#{plural_forms.nplurals}, from #{plural_forms.location})"
            end
          end

          gettext_plural_forms[locale] = plural_forms
        end

        def gettext_plural_forms
          @gettext_plural_forms ||= {}
        end

        def normalize(locale, data, filename = nil)
          data.inject({}) do |result, (key, value)|
            unless key.nil? || key.empty?
              key = key.gsub(I18n::Gettext::CONTEXT_SEPARATOR, '|')
              key, value = normalize_pluralization(locale, key, value, filename) if key.index("\000")

              parts = key.split('|').reverse
              normalized = parts.inject({}) do |_normalized, part|
                { part => _normalized.empty? ? value : _normalized }
              end

              Utils.deep_merge!(result, normalized)
            end
            result
          end
        end

        def normalize_pluralization(locale, key, value, filename = nil)
          # FIXME po_parser includes \000 chars that can not be turned into Symbols
          key = key.gsub("\000", I18n::Gettext::PLURAL_SEPARATOR).split(I18n::Gettext::PLURAL_SEPARATOR).first

          values = value.split("\000")
          plural_forms = gettext_plural_forms[locale]

          result = {}
          if plural_forms
            if values.size != plural_forms.nplurals
              raise I18n::Gettext::PluralForms::PluralCountMismatch,
                "#{filename}: msgid #{key.inspect} has #{values.size} plural translations, " \
                "but the Plural-Forms header declares nplurals=#{plural_forms.nplurals} (locale: #{locale})"
            end
            values.each_with_index { |_value, ix| result[ix] = _value }
          else
            keys = I18n::Gettext.plural_keys(locale)
            raise "invalid number of plurals: #{values.size}, keys: #{keys.inspect} on #{locale} locale for msgid #{key.inspect} with values #{values.inspect}" if values.size != keys.size
            values.each_with_index { |_value, ix| result[keys[ix]] = _value }
          end
          [key, result]
        end

        # Picks the msgstr[index] selected by the Plural-Forms rule declared
        # in the PO file itself. Entries that were not loaded from a PO file
        # with a Plural-Forms header fall back to the default behaviour.
        def pluralize(locale, entry, count)
          plural_forms = gettext_plural_forms[locale]

          if plural_forms && entry.is_a?(Hash) && entry.keys.any? { |key| key.is_a?(Integer) }
            index = plural_forms.call(count)
            raise InvalidPluralizationData.new(entry, count, index) unless entry.has_key?(index)
            entry[index]
          else
            super
          end
        end

    end
  end
end
