# frozen_string_literal: true

module I18n
  module Gettext
    PLURAL_SEPARATOR  = "\001"
    CONTEXT_SEPARATOR = "\004"

    autoload :Helpers, 'i18n/gettext/helpers'
    autoload :PluralForm, 'i18n/gettext/plural_form'

    @@plural_keys = { :en => [:one, :other] }
    @@plural_forms_conflict = :raise

    class << self
      # returns an array of plural keys for the given locale or the whole hash
      # of locale mappings to plural keys so that we can convert from gettext's
      # integer-index based style
      # TODO move this information to the pluralization module
      def plural_keys(*args)
        args.empty? ? @@plural_keys : @@plural_keys[args.first] || @@plural_keys[:en]
      end

      def plural_forms_conflict
        @@plural_forms_conflict
      end

      def plural_forms_conflict=(strategy)
        unless [:raise, :first, :last].include?(strategy)
          raise ArgumentError, "unknown Plural-Forms conflict strategy #{strategy.inspect}; expected one of :raise, :first, or :last"
        end

        @@plural_forms_conflict = strategy
      end

      def extract_scope(msgid, separator)
        scope = msgid.to_s.split(separator)
        msgid = scope.pop
        [scope, msgid]
      end
    end
  end
end
