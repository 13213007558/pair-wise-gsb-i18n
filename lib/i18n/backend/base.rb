# frozen_string_literal: true

require 'yaml'
require 'json'

module I18n
  module Backend
    module Base
      include I18n::Backend::Transliterator

      # Accepts a list of paths to translation files. Loads translations from
      # plain Ruby (*.rb), YAML files (*.yml), or JSON files (*.json). See #load_rb, #load_yml, and #load_json
      # for details.
      def load_translations(*filenames)
        filenames = I18n.load_path if filenames.empty?
        filenames.flatten.each do |filename|
          loaded_translations = load_file(filename)
          yield filename, loaded_translations if block_given?
        end
      end

      # This method receives a locale, a data hash and options for storing translations.
      # Should be implemented
      def store_translations(locale, data, options = EMPTY_HASH)
        raise NotImplementedError
      end

      def translate(locale, key, options = EMPTY_HASH)
        raise I18n::ArgumentError if (key.is_a?(String) || key.is_a?(Symbol)) && key.empty?
        raise InvalidLocale.new(locale) unless locale
        return nil if key.nil? && !options.key?(:default)

        entry = lookup(locale, key, options[:scope], options) unless key.nil?

        if entry.nil? && options.key?(:default)
          entry = default(locale, key, options[:default], options)
        else
          entry = resolve_entry(locale, key, entry, options)
        end

        count = options[:count]

        if entry.nil? && (subtrees? || !count)
          if (options.key?(:default) && !options[:default].nil?) || !options.key?(:default)
            throw(:exception, I18n::MissingTranslation.new(locale, key, options))
          end
        end

        entry = entry.dup if entry.is_a?(String)
        entry = pluralize(locale, entry, count) if count

        if entry.nil? && !subtrees?
          throw(:exception, I18n::MissingTranslation.new(locale, key, options))
        end

        deep_interpolation = options[:deep_interpolation]
        skip_interpolation = options[:skip_interpolation]
        values = Utils.except(options, *RESERVED_KEYS) unless options.empty?
        if !skip_interpolation && values && !values.empty?
          entry = if deep_interpolation
            deep_interpolate(locale, entry, values)
          else
            interpolate(locale, entry, values)
          end
        elsif entry.is_a?(String) && entry =~ I18n.reserved_keys_pattern
          raise ReservedInterpolationKey.new($1.to_sym, entry)
        end
        entry
      end

      def exists?(locale, key, options = EMPTY_HASH)
        lookup(locale, key, options[:scope]) != nil
      end

      # Acts the same as +strftime+, but uses a localized version of the
      # format string. Takes a key from the date/time formats translations as
      # a format argument (<em>e.g.</em>, <tt>:short</tt> in <tt>:'date.formats'</tt>).
      def localize(locale, object, format = :default, options = EMPTY_HASH)
        if object.nil? && options.include?(:default)
          return options[:default]
        end
        raise ArgumentError, "Object must be a Date, DateTime or Time object. #{object.inspect} given." unless object.respond_to?(:strftime)

        if Symbol === format
          key  = format
          type = object.respond_to?(:sec) ? 'time' : 'date'
          options = options.merge(:raise => true, :object => object, :locale => locale)
          format  = I18n.t(:"#{type}.formats.#{key}", **options)
        end

        format = translate_localization_format(locale, object, format, options)
        object.strftime(format)
      end

      def localize_interval(locale, start_object, end_object = nil, format = :default, options = EMPTY_HASH)
        if start_object.respond_to?(:first) && start_object.respond_to?(:last)
          start_object, end_object = start_object.first, start_object.last
        end

        unless start_object.respond_to?(:strftime) && end_object.respond_to?(:strftime)
          raise ArgumentError, "Objects must be Dates, DateTimes or Times. #{start_object.inspect}, #{end_object.inspect} given."
        end
        if start_object.respond_to?(:sec) != end_object.respond_to?(:sec)
          raise ArgumentError, "Interval objects must be the same type. #{start_object.inspect}, #{end_object.inspect} given."
        end

        interval_options = options.dup
        return_fragments = interval_options.delete(:fragments) || interval_options.delete(:parts)
        time_zone = interval_options.delete(:time_zone) || interval_options.delete(:zone)
        start_object = localize_interval_in_time_zone(start_object, time_zone)
        end_object = localize_interval_in_time_zone(end_object, time_zone)

        type = start_object.respond_to?(:sec) || end_object.respond_to?(:sec) ? 'time' : 'date'
        granularity = interval_granularity(start_object, end_object)
        separator = resolve_interval_separator(locale, type, interval_options)
        pattern = resolve_interval_pattern(locale, type, format, granularity, interval_options)
        pattern = nil unless valid_interval_pattern?(
          pattern, granularity, separator, start_object, end_object
        )

        unless pattern
          return localize_interval_fallback(
            locale,
            start_object,
            end_object,
            type,
            granularity,
            format.is_a?(::String) ? :default : format,
            separator,
            interval_options,
            return_fragments
          )
        end

        parts = localize_interval_parts(
          locale, start_object, end_object, pattern, granularity, separator, interval_options
        )
        string = parts.map { |part| part[:value] }.join

        return string unless return_fragments
        { :string => string, :fragments => parts }
      end

      # Returns an array of locales for which translations are available
      # ignoring the reserved translation meta data key :i18n.
      def available_locales
        raise NotImplementedError
      end

      def reload!
        eager_load! if eager_loaded?
      end

      def eager_load!
        @eager_loaded = true
      end

      protected

        INTERVAL_GRANULARITIES = [
          :year, :month, :day, :hour, :minute, :second, :offset
        ].freeze

        INTERVAL_DIRECTIVE_FIELDS = {
          'Y' => :year, 'C' => :year, 'G' => :year,
          'b' => :month, 'B' => :month, 'h' => :month, 'm' => :month,
          'd' => :day, 'e' => :day, 'j' => :day,
          'H' => :hour, 'k' => :hour, 'I' => :hour, 'l' => :hour,
          'p' => :hour, 'P' => :hour,
          'M' => :minute,
          'S' => :second, 'L' => :second, 'N' => :second, 's' => :second,
          'z' => :offset, 'Z' => :offset,
        }.freeze

        INTERVAL_COMPOSITE_DIRECTIVES = {
          'c' => :second, 'D' => :day, 'F' => :day, 'r' => :hour,
          'R' => :minute, 'T' => :second, 'v' => :day, 'V' => :second,
          'x' => :day, 'X' => :second,
        }.freeze

        def eager_loaded?
          @eager_loaded ||= false
        end

        def interval_granularity(start_object, end_object)
          INTERVAL_GRANULARITIES.each do |granularity|
            next if granularity == :offset && !start_object.respond_to?(:utc_offset)
            return granularity if interval_field_differs?(start_object, end_object, granularity)
          end
          :none
        end

        def interval_field_differs?(start_object, end_object, field)
          case field
          when :year then start_object.year != end_object.year
          when :month then start_object.mon != end_object.mon
          when :day then start_object.mday != end_object.mday
          when :hour
            (!start_object.respond_to?(:hour) || !end_object.respond_to?(:hour) ||
              interval_field_value(start_object, :hour) != interval_field_value(end_object, :hour))
          when :minute
            (!start_object.respond_to?(:min) || !end_object.respond_to?(:min) ||
              interval_field_value(start_object, :min) != interval_field_value(end_object, :min))
          when :second
            (!start_object.respond_to?(:sec) || !end_object.respond_to?(:sec) ||
              interval_field_value(start_object, :sec) != interval_field_value(end_object, :sec))
          when :offset
            (!start_object.respond_to?(:utc_offset) || !end_object.respond_to?(:utc_offset) ||
              start_object.utc_offset != end_object.utc_offset ||
              (start_object.respond_to?(:zone) && end_object.respond_to?(:zone) &&
                start_object.zone != end_object.zone)
              )
          end
        end

        def interval_field_value(object, field)
          object.respond_to?(field) ? object.public_send(field) : 0
        end

        def resolve_interval_pattern(locale, type, format, granularity, options)
          return nil if granularity == :none
          return format if format.is_a?(::String)

          format_name = format.is_a?(::Symbol) ? format : :default
          patterns = catch(:exception) do
            I18n.t(
              :"#{type}.interval_formats.#{format_name}",
              **options.merge(:throw => true, :locale => locale)
            )
          end
          return nil unless patterns.is_a?(::Hash)

          patterns[granularity] || patterns[granularity.to_s] ||
            interval_pattern_alias(patterns, granularity)
        end

        def interval_pattern_alias(patterns, granularity)
          case granularity
          when :offset
            patterns[:zone] || patterns['zone'] ||
              patterns[:time_zone] || patterns['time_zone']
          when :hour
            patterns[:meridian] || patterns['meridian'] ||
              patterns[:am_pm] || patterns['am_pm']
          end
        end

        def valid_interval_pattern?(pattern, granularity, separator = ' – ', start_object = nil, end_object = nil)
          return false unless pattern.is_a?(::String)
          return true if granularity == :none

          minimum_rank = INTERVAL_GRANULARITIES.index(granularity)
          tokens = parse_interval_format(pattern, granularity, separator)
          fields = tokens.map { |token| token[:field] }.uniq
          fields.select do |field|
            rank = INTERVAL_GRANULARITIES.index(field)
            rank && rank < minimum_rank
          end.all? do |field|
            count = tokens.count { |token| token[:field] == field }
            count >= 2 ||
              !start_object || !end_object || !interval_field_differs?(start_object, end_object, field)
          end && tokens.count { |token| token[:field] == granularity } >= 2
        end

        def localize_interval_parts(locale, start_object, end_object, pattern, granularity, separator, options)
          tokens = parse_interval_format(pattern, granularity, separator)
          parts = tokens.filter_map do |token|
            object = token[:source] == :end ? end_object : start_object
            value = if token[:directive]
              localize_interval_token(locale, object, token[:value], options)
            else
              token[:value]
            end
            next if value.empty?
            { :source => token[:source], :value => value }
          end

          parts.each_with_object([]) do |part, merged|
            if merged.last && merged.last[:source] == part[:source]
              merged.last[:value] += part[:value]
            else
              merged << part
            end
          end
        end

        def parse_interval_format(pattern, granularity = :none, separator = ' – ')
          tokens = []
          scanner = /%[\-\^#0_:+ ]*(?:[0-9]+|\*)?(?:\.[0-9]+)?[EO]?[a-zA-Z%]|./m

          pattern.scan(scanner) do |text|
            if text == '%%'
              append_interval_literal(tokens, '%')
              next
            end

            directive = text[-1]
            field = INTERVAL_DIRECTIVE_FIELDS.fetch(directive, nil) ||
              INTERVAL_COMPOSITE_DIRECTIVES[directive]

            unless field
              append_interval_literal(tokens, text)
              next
            end

            tokens << {
              :value => text,
              :directive => true,
              :field => field,
              :directive_name => directive,
              :source => :shared,
            }
          end
          assign_interval_sources(tokens, granularity, separator)
        end

        def assign_interval_sources(tokens, granularity, separator)
          return tokens if granularity == :none

          maximum_rank = INTERVAL_GRANULARITIES.index(granularity)
          return tokens if maximum_rank.nil?

          anchor_name = tokens.find do |token|
            token[:directive] && token[:field] == granularity
          end
          return tokens unless anchor_name
          anchor_name = anchor_name[:directive_name]
          anchor_occurrences = 0

          tokens.each do |token|
            next unless token[:directive]

            rank = INTERVAL_GRANULARITIES.index(token[:field])
            if rank.nil? || rank < maximum_rank
              token[:source] = :shared
              next
            end

            if token[:field] == granularity && token[:directive_name] == anchor_name
              anchor_occurrences += 1
            end

            token[:source] = case
                             when anchor_occurrences < 2 then :start
                             when anchor_occurrences == 2 then :end
                             else :shared
                             end
          end
          assign_interval_literal_sources(tokens, separator)
          tokens
        end

        def assign_interval_literal_sources(tokens, separator)
          current_source = :shared

          tokens.each_with_index do |token, index|
            if token[:directive]
              current_source = token[:source]
              next
            end

            next_source = tokens[index + 1..].find { |candidate| candidate[:directive] }&.dig(:source) || current_source
            before, connection, after = split_interval_literal(token[:value], separator)

            if connection
              replacement = []
              replacement << { :value => before, :source => current_source } unless before.empty?
              replacement << { :value => connection, :source => :shared }
              replacement << { :value => after, :source => next_source } unless after.empty?
              tokens[index] = replacement
            else
              token[:source] = current_source
            end
          end
          tokens.flatten!
        end

        def split_interval_literal(value, separator)
          index = value.index(separator)
          return [value, nil, nil] unless index

          [value[0, index], separator, value[index + separator.length..]]
        end

        def append_interval_literal(tokens, text)
          if tokens.last && !tokens.last[:directive] && tokens.last[:source] == :shared
            tokens.last[:value] += text
          else
            tokens << { :value => text, :directive => false, :field => nil, :source => :shared }
          end
        end

        def localize_interval_token(locale, object, format, options)
          format = translate_localization_format(locale, object, format, options)
          object.strftime(format)
        end

        def localize_interval_in_time_zone(object, time_zone)
          return object if time_zone.nil?
          if time_zone.respond_to?(:utc_to_local)
            return time_zone.utc_to_local(object.respond_to?(:utc) ? object.utc : object)
          end
          return object.getlocal(time_zone) if object.respond_to?(:getlocal)
          return object.new_offset(time_zone) if object.respond_to?(:new_offset)

          object
        end

        def localize_interval_fallback(locale, start_object, end_object, type, granularity, format, separator, options, return_fragments)
          start_string = localize_interval_fallback_endpoint(
            locale, start_object, type, granularity, format, options
          )
          end_string = localize_interval_fallback_endpoint(
            locale, end_object, type, granularity, format, options
          )
          string = "#{start_string}#{separator}#{end_string}"
          return string unless return_fragments

          {
            :string => string,
            :fragments => [
              { :source => :start, :value => start_string },
              { :source => :shared, :value => separator },
              { :source => :end, :value => end_string },
            ],
          }
        end

        def localize_interval_fallback_endpoint(locale, object, type, granularity, format, options)
          string = I18n.localize(object, :locale => locale, :format => format, **options)
          return string unless granularity == :offset &&
            !interval_format_includes_time_zone?(locale, type, format)

          "#{string} #{object.strftime('%z')}"
        end

        def interval_format_includes_time_zone?(locale, type, format)
          return format.to_s.match?(/%[\-\^#0_:+ ]*(?:z|Z)/) unless format.is_a?(::Symbol)

          resolved = catch(:exception) do
            I18n.t(:"#{type}.formats.#{format}", :locale => locale, :throw => true)
          end
          resolved.is_a?(::String) && resolved.match?(/%[\-\^#0_:+ ]*(?:z|Z)/)
        end

        def resolve_interval_separator(locale, type, options)
          return options[:interval_separator] if options.key?(:interval_separator)

          separator = catch(:exception) do
            I18n.t(:"#{type}.interval_formats.separator", :locale => locale, :throw => true)
          end if type
          separator.is_a?(::String) ? separator : ' – '
        end

        # The method which actually looks up for the translation in the store.
        def lookup(locale, key, scope = [], options = EMPTY_HASH)
          raise NotImplementedError
        end

        def subtrees?
          true
        end

        # Evaluates defaults.
        # If given subject is an Array, it walks the array and returns the
        # first translation that can be resolved. Otherwise it tries to resolve
        # the translation directly.
        def default(locale, object, subject, options = EMPTY_HASH)
          if options.size == 1 && options.has_key?(:default)
            options = {}
          else
            options = Utils.except(options, :default)
          end

          case subject
          when Array
            subject.each do |item|
              result = resolve(locale, object, item, options)
              return result unless result.nil?
            end and nil
          else
            resolve(locale, object, subject, options)
          end
        end

        # Resolves a translation.
        # If the given subject is a Symbol, it will be translated with the
        # given options. If it is a Proc then it will be evaluated. All other
        # subjects will be returned directly.
        def resolve(locale, object, subject, options = EMPTY_HASH)
          return subject if options[:resolve] == false
          result = catch(:exception) do
            case subject
            when Symbol
              I18n.translate(
                subject,
                **options.merge(
                  :locale => locale,
                  :throw => true,
                  :skip_interpolation => true
                )
              )
            when Proc
              date_or_time = options.delete(:object) || object
              resolve(locale, object, subject.call(date_or_time, **options))
            else
              subject
            end
          end
          result unless result.is_a?(MissingTranslation)
        end
        alias_method :resolve_entry, :resolve

        # Picks a translation from a pluralized mnemonic subkey according to English
        # pluralization rules :
        # - It will pick the :one subkey if count is equal to 1.
        # - It will pick the :other subkey otherwise.
        # - It will pick the :zero subkey in the special case where count is
        #   equal to 0 and there is a :zero subkey present. This behaviour is
        #   not standard with regards to the CLDR pluralization rules.
        # Other backends can implement more flexible or complex pluralization rules.
        def pluralize(locale, entry, count)
          entry = entry.reject { |k, _v| k == :attributes } if entry.is_a?(Hash)
          return entry unless entry.is_a?(Hash) && count

          key = pluralization_key(entry, count)
          raise InvalidPluralizationData.new(entry, count, key) unless entry.has_key?(key)
          entry[key]
        end

        # Interpolates values into a given subject.
        #
        #   if the given subject is a string then:
        #   method interpolates "file %{file} opened by %%{user}", :file => 'test.txt', :user => 'Mr. X'
        #   # => "file test.txt opened by %{user}"
        #
        #   if the given subject is an array then:
        #   each element of the array is recursively interpolated (until it finds a string)
        #   method interpolates ["yes, %{user}", ["maybe no, %{user}", "no, %{user}"]], :user => "bartuz"
        #   # => ["yes, bartuz", ["maybe no, bartuz", "no, bartuz"]]
        def interpolate(locale, subject, values = EMPTY_HASH)
          return subject if values.empty?

          case subject
          when ::String then I18n.interpolate(subject, values)
          when ::Array then subject.map { |element| interpolate(locale, element, values) }
          else
            subject
          end
        end

        # Deep interpolation
        #
        #   deep_interpolate { people: { ann: "Ann is %{ann}", john: "John is %{john}" } },
        #                    ann: 'good', john: 'big'
        #   #=> { people: { ann: "Ann is good", john: "John is big" } }
        def deep_interpolate(locale, data, values = EMPTY_HASH)
          return data if values.empty?

          case data
          when ::String
            I18n.interpolate(data, values)
          when ::Hash
            data.each_with_object({}) do |(k, v), result|
              result[k] = deep_interpolate(locale, v, values)
            end
          when ::Array
            data.map do |v|
              deep_interpolate(locale, v, values)
            end
          else
            data
          end
        end

        # Loads a single translations file by delegating to #load_rb or
        # #load_yml depending on the file extension and directly merges the
        # data to the existing translations. Raises I18n::UnknownFileType
        # for all other file extensions.
        def load_file(filename)
          type = File.extname(filename).tr('.', '').downcase
          raise UnknownFileType.new(type, filename) unless respond_to?(:"load_#{type}", true)
          data, keys_symbolized = send(:"load_#{type}", filename)
          unless data.is_a?(Hash)
            raise InvalidLocaleData.new(filename, 'expects it to return a hash, but does not')
          end
          data.each { |locale, d| store_translations(locale, d || {}, skip_symbolize_keys: keys_symbolized) }

          data
        end

        # Loads a plain Ruby translations file. eval'ing the file must yield
        # a Hash containing translation data with locales as toplevel keys.
        def load_rb(filename)
          translations = eval(IO.read(filename), binding, filename.to_s)
          [translations, false]
        end

        # Loads a YAML translations file. The data must have locales as
        # toplevel keys.
        def load_yml(filename)
          begin
            if YAML.respond_to?(:unsafe_load_file) # Psych 4.0 way
              [YAML.unsafe_load_file(filename, symbolize_names: true, freeze: true), true]
            else
              [YAML.load_file(filename), false]
            end
          rescue TypeError, ScriptError, StandardError => e
            raise InvalidLocaleData.new(filename, e.inspect)
          end
        end
        alias_method :load_yaml, :load_yml

        # Loads a JSON translations file. The data must have locales as
        # toplevel keys.
        def load_json(filename)
          begin
            # Use #load_file as a proxy for a version of JSON where symbolize_names and freeze are supported.
            if ::JSON.respond_to?(:load_file)
              [::JSON.load_file(filename, symbolize_names: true, freeze: true), true]
            else
              [::JSON.parse(File.read(filename)), false]
            end
          rescue TypeError, StandardError => e
            raise InvalidLocaleData.new(filename, e.inspect)
          end
        end

        def translate_localization_format(locale, object, format, options)
          format.to_s.gsub(/%(|\^)[aAbBpP]/) do |match|
            case match
            when '%a' then I18n.t!(:"date.abbr_day_names",                  :locale => locale, :format => format)[object.wday]
            when '%^a' then I18n.t!(:"date.abbr_day_names",                 :locale => locale, :format => format)[object.wday].upcase
            when '%A' then I18n.t!(:"date.day_names",                       :locale => locale, :format => format)[object.wday]
            when '%^A' then I18n.t!(:"date.day_names",                      :locale => locale, :format => format)[object.wday].upcase
            when '%b' then I18n.t!(:"date.abbr_month_names",                :locale => locale, :format => format)[object.mon]
            when '%^b' then I18n.t!(:"date.abbr_month_names",               :locale => locale, :format => format)[object.mon].upcase
            when '%B' then I18n.t!(:"date.month_names",                     :locale => locale, :format => format)[object.mon]
            when '%^B' then I18n.t!(:"date.month_names",                    :locale => locale, :format => format)[object.mon].upcase
            when '%p' then I18n.t!(:"time.#{(object.respond_to?(:hour) ? object.hour : 0) < 12 ? :am : :pm}", :locale => locale, :format => format).upcase
            when '%P' then I18n.t!(:"time.#{(object.respond_to?(:hour) ? object.hour : 0) < 12 ? :am : :pm}", :locale => locale, :format => format).downcase
            end
          end
        rescue MissingTranslationData => e
          e.message
        end

        def pluralization_key(entry, count)
          key = :zero if count == 0 && entry.has_key?(:zero)
          key ||= count == 1 ? :one : :other
        end
    end
  end
end
