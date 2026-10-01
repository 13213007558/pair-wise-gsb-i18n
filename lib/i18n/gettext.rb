# frozen_string_literal: true

module I18n
  module Gettext
    PLURAL_SEPARATOR  = "\001"
    CONTEXT_SEPARATOR = "\004"

    autoload :Helpers, 'i18n/gettext/helpers'
    autoload :PluralForms, 'i18n/gettext/plural_forms'

    @@plural_keys = { :en => [:one, :other] }
    @@plural_forms_conflict_strategy = :raise

    class << self
      # returns an array of plural keys for the given locale or the whole hash
      # of locale mappings to plural keys so that we can convert from gettext's
      # integer-index based style
      # TODO move this information to the pluralization module
      def plural_keys(*args)
        args.empty? ? @@plural_keys : @@plural_keys[args.first] || @@plural_keys[:en]
      end

      # How the Gettext backend reacts when several PO files for the same
      # locale declare different Plural-Forms rules:
      #
      # * :raise (default) - raise I18n::Gettext::PluralForms::ConflictingRules
      # * :first           - keep the rule declared by the first loaded file
      # * :last            - use the rule declared by the last loaded file
      #
      # Files declaring identical rules never conflict.
      def plural_forms_conflict_strategy
        @@plural_forms_conflict_strategy
      end

      def plural_forms_conflict_strategy=(strategy)
        unless [:raise, :first, :last].include?(strategy)
          raise ArgumentError, "unknown Plural-Forms conflict strategy #{strategy.inspect}, " \
            "expected one of :raise, :first, :last"
        end
        @@plural_forms_conflict_strategy = strategy
      end

      def extract_scope(msgid, separator)
        scope = msgid.to_s.split(separator)
        msgid = scope.pop
        [scope, msgid]
      end
    end
  end
end
