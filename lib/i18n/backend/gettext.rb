# frozen_string_literal: true

require 'i18n/gettext'
require 'i18n/gettext/po_parser'
require 'i18n/gettext/plural_form'

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

    module Gettext
      class PoData < Hash
        def set_comment(msgid_or_sym, comment)
          # ignore
        end
      end

      class PoPluralTranslation < ::Array
        attr_accessor :plural_form

        def initialize(values, plural_form)
          super(values)
          @plural_form = plural_form
        end

        def po_plural_translation?
          true
        end
      end

      def reload!
        @gettext_plural_forms = nil
        super
      end

      protected
        def load_po(filename)
          locale = ::File.basename(filename, '.po').to_sym
          parsed_data = parse(filename)
          candidate_form = plural_form_from_header(locale, parsed_data, filename)
          plural_form = select_gettext_plural_form(locale, candidate_form, filename) if candidate_form
          data = normalize(locale, parsed_data, plural_form, filename)
          if plural_form
            gettext_plural_forms[locale] = plural_form
            data[:i18n] = { :plural => { :rule => plural_form } }
          end
          [{ locale => data }, true]
        end

        def parse(filename)
          GetText::PoParser.new.parse(::File.read(filename), PoData.new)
        end

        def normalize(locale, data, plural_form = nil, filename = nil)
          data.inject({}) do |result, (key, value)|
            unless key.nil? || key.empty?
              key = key.gsub(I18n::Gettext::CONTEXT_SEPARATOR, '|')
              key, value = normalize_pluralization(locale, key, value, plural_form, filename) if key.index("\000")

              parts = key.split('|').reverse
              normalized = parts.inject({}) do |_normalized, part|
                { part.to_sym => _normalized.empty? ? value : _normalized }
              end

              Utils.deep_merge!(result, normalized)
            end
            result
          end
        end

        def normalize_pluralization(locale, key, value, plural_form = nil, filename = nil)
          # FIXME po_parser includes \000 chars that can not be turned into Symbols
          key = key.gsub("\000", I18n::Gettext::PLURAL_SEPARATOR).split(I18n::Gettext::PLURAL_SEPARATOR).first

          values = value.split("\000")

          if plural_form
            unless values.size == plural_form.nplurals
              raise I18n::Gettext::PluralForm::Error, "#{filename}: invalid number of plural translations for #{locale.inspect} msgid #{key.inspect}: expected #{plural_form.nplurals}, got #{values.size}"
            end

            [key, PoPluralTranslation.new(values, plural_form)]
          else
            keys = I18n::Gettext.plural_keys(locale)
            unless values.size == keys.size
              raise "invalid number of plurals: #{values.size}, keys: #{keys.inspect} on #{locale} locale for msgid #{key.inspect} with values #{values.inspect}"
            end

            result = {}
            values.each_with_index { |_value, ix| result[keys[ix]] = _value }
            [key, result]
          end
        end

        def pluralize(locale, entry, count)
          if entry.is_a?(PoPluralTranslation)
            plural_form = entry.plural_form || gettext_plural_forms[locale]
            index = plural_form.call(count)
            unless index.is_a?(::Integer) && index >= 0 && entry.size > index
              raise I18n::InvalidPluralizationData.new(entry, count, index)
            end

            return entry[index]
          end

          super
        end

      private

        def gettext_plural_forms
          @gettext_plural_forms ||= {}
        end

        def select_gettext_plural_form(locale, candidate_form, filename)
          existing_form = gettext_plural_forms[locale]
          return candidate_form unless existing_form && existing_form != candidate_form

          if existing_form.nplurals != candidate_form.nplurals
            raise I18n::Gettext::PluralForm::Error, "conflicting Plural-Forms nplurals for #{locale.inspect}: #{describe_plural_form(existing_form)} conflicts with #{describe_plural_form(candidate_form)} from #{filename}; configure separate locales when files use different plural entry counts"
          end

          case I18n::Gettext.plural_forms_conflict
          when :raise
            raise I18n::Gettext::PluralForm::Error, "conflicting Plural-Forms for #{locale.inspect}: #{describe_plural_form(existing_form)} conflicts with #{describe_plural_form(candidate_form)} from #{filename}"
          when :first
            existing_form
          when :last
            candidate_form
          end
        end

        def describe_plural_form(plural_form)
          source = "nplurals=#{plural_form.nplurals}; plural=#{plural_form.expression}"
          plural_form.filename ? "#{source} (#{plural_form.filename})" : source
        end

        def plural_form_from_header(locale, data, filename)
          header = data['']
          return nil if header.nil? || header.empty?

          I18n::Gettext::PluralForm.parse(header, filename: filename)
        rescue I18n::Gettext::PluralForm::Error => error
          raise I18n::Gettext::PluralForm::Error, "#{filename}: unable to load Plural-Forms for #{locale.inspect}: #{error.message}"
        end

    end
  end
end
