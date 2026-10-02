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

      def localize_interval(locale, start_object, end_object, format = :default, options = EMPTY_HASH)
        return options[:default] if start_object.nil? && end_object.nil? && options.include?(:default)

        validate_interval_object!(start_object)
        validate_interval_object!(end_object)

        type = interval_type(start_object, end_object)
        start_in_zone, end_in_zone = interval_objects_in_zone(start_object, end_object, options)
        granularity = interval_granularity(start_in_zone, end_in_zone)
        separator = interval_separator(locale, options)
        pattern = interval_pattern(locale, type, format, granularity, separator, options)

        if pattern
          render_interval_pattern(locale, pattern, start_object, end_object, start_in_zone, end_in_zone, granularity, options)
        else
          localize_interval_fallback(locale, start_object, end_object, start_in_zone, end_in_zone, format, separator, granularity, options)
        end
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

        INTERVAL_GRANULARITIES = %i[same year month day meridian hour minute second zone].freeze
        INTERVAL_PATTERN = /%\{(shared|start|end)(?::([^}]*))?\}/.freeze
        TIME_ZONE_OPTIONS = %i[time_zone timezone zone].freeze

        def validate_interval_object!(object)
          return if object.respond_to?(:strftime)

          raise ArgumentError, "Object must be a Date, DateTime or Time object. #{object.inspect} given."
        end

        def interval_type(start_object, end_object)
          if start_object.respond_to?(:sec) || end_object.respond_to?(:sec)
            'time'
          else
            'date'
          end
        end

        def interval_objects_in_zone(start_object, end_object, options)
          time_zone = TIME_ZONE_OPTIONS.lazy.map { |key| options[key] }.reject(&:nil?).first
          [start_object, end_object].map do |object|
            object_in_interval_zone(object, time_zone)
          end
        end

        def object_in_interval_zone(object, time_zone)
          return object unless time_zone
          return convert_date_time_to_interval_zone(object, time_zone) unless object.respond_to?(:getlocal)

          if time_zone.respond_to?(:utc_to_local)
            object_in_named_interval_zone(object, time_zone)
          else
            object.getlocal(time_zone.to_str)
          end
        rescue TypeError, ArgumentError
          raise ArgumentError, "Unsupported time zone: #{time_zone.inspect}."
        end

        def object_in_named_interval_zone(object, time_zone)
          time = object.respond_to?(:utc) ? object.utc : object.to_time.utc
          local_time = time_zone.utc_to_local(time)
          offset = if local_time.respond_to?(:utc_offset)
            local_time.utc_offset
          elsif time_zone.respond_to?(:period_for_utc)
            time_zone.period_for_utc(time).utc_total_offset
          else
            0
          end
          ::Time.new(local_time.year, local_time.mon, local_time.day, local_time.hour, local_time.min, local_time.sec, offset)
        end

        def convert_date_time_to_interval_zone(object, time_zone)
          time = object.to_time
          converted = object_in_interval_zone(time, time_zone)
          converted.to_datetime
        end

        def interval_granularity(start_object, end_object)
          if start_object.year != end_object.year
            :year
          elsif start_object.mon != end_object.mon
            :month
          elsif start_object.day != end_object.day
            :day
          elsif interval_has_time?(start_object, end_object) && (start_object.hour / 12) != (end_object.hour / 12)
            :meridian
          elsif interval_has_time?(start_object, end_object) && start_object.hour != end_object.hour
            :hour
          elsif interval_has_time?(start_object, end_object) && start_object.min != end_object.min
            :minute
          elsif start_object.respond_to?(:sec) && end_object.respond_to?(:sec) && start_object.sec != end_object.sec
            :second
          elsif interval_has_time?(start_object, end_object) && interval_offsets_differ?(start_object, end_object)
            :zone
          else
            :same
          end
        end

        def interval_has_time?(start_object, end_object)
          start_object.respond_to?(:hour) && end_object.respond_to?(:hour)
        end

        def interval_offsets_differ?(start_object, end_object)
          start_offset = interval_offset(start_object)
          end_offset = interval_offset(end_object)
          start_offset && end_offset && start_offset != end_offset
        end

        def interval_offset(object)
          if object.respond_to?(:utc_offset)
            object.utc_offset
          elsif object.respond_to?(:offset)
            object.offset * 86400
          end
        end

        def interval_pattern(locale, type, format, granularity, separator, options)
          return nil unless INTERVAL_GRANULARITIES.include?(granularity)

          table = interval_pattern_table(locale, type, format, interval_lookup_options(locale, options))
          pattern = granularity_keys(granularity).map do |key|
            table[key] || table[key.to_s]
          end.compact.first
          pattern = "%{start:#{pattern.first}}#{separator}%{end:#{pattern.last}}" if pattern.is_a?(::Array) && pattern.size == 2
          pattern.to_s if pattern
        end

        def granularity_keys(granularity)
          aliases = case granularity
          when :zone
            %i[zone offset time_zone]
          when :meridian
            %i[meridian am_pm period]
          else
            [granularity]
          end
          aliases
        end

        def interval_pattern_table(locale, type, format, lookup_options)
          format_keys = format.is_a?(Symbol) ? [format, format.to_s] : [format.to_s]
          format_keys.map do |format_key|
            [
              [type, :intervals, :formats, format_key],
              [type, :interval, :formats, format_key],
              [type, :formats, :intervals, format_key],
              [type, :formats, :interval, format_key]
            ].map do |key|
              catch(:exception) do
                result = I18n.t(key.join('.').to_sym, **lookup_options)
                result if result.is_a?(Hash)
              end
            end
          end.flatten.compact.grep(Hash).first || EMPTY_HASH
        end

        def interval_lookup_options(locale, options)
          options.slice(:fallback, :fallback_in_progress, :fallback_original_locale, :separator).merge(
            :locale => locale,
            :throw => true,
            :skip_interpolation => true
          )
        end

        def interval_separator(locale, _options)
          I18n.t(:'support.interval.default', :locale => locale, :default => '–', :skip_interpolation => true)
        end

        def render_interval_pattern(locale, pattern, start_object, end_object, start_in_zone, end_in_zone, granularity, options)
          objects = { :start => start_in_zone, :end => end_in_zone, :shared => start_in_zone }
          parts = []
          position = 0
          started = false
          finished = false

          pattern.gsub(INTERVAL_PATTERN) do
            match = ::Regexp.last_match
            if match.begin(0) > position
              literal = pattern[position...match.begin(0)]
              part = { :source => :shared, :value => literal }
              parts << part unless started && !finished
            end

            source = match[1].to_sym
            started = true if source == :start
            finished = true if source == :end
            if source == :shared && match[2].nil?
              value = ''
            else
              source_format = match[2] || default_interval_source_format(source, objects[source])
              source_format = ensure_interval_offset(source_format, source, granularity)
              value = localize(locale, objects[source], source_format, options)
            end
            part = { :source => source, :value => value }
            part[:role] = :separator if source == :shared && started && !finished
            parts << part unless part[:role] == :separator
            position = match.end(0)
            value
          end.tap do
            parts << { :source => :shared, :value => pattern[position..] } if position < pattern.length && parts.any? { |part| part[:source] == :end }
          end.then do |result|
            interval_result(result, start_object, end_object, parts, options)
          end
        end

        def ensure_interval_offset(format, source, granularity)
          return format unless granularity == :zone
          return format if source == :shared
          return format if /%[-_0^#:+ ]*:?[zZ]/.match?(format)

          "#{format} %z"
        end

        def default_interval_source_format(_source, object)
          return '%Y-%m-%d' unless object.respond_to?(:sec)

          '%Y-%m-%d %H:%M:%S %z'
        end

        def localize_interval_fallback(locale, start_object, end_object, start_in_zone, end_in_zone, format, separator, granularity, options)
          start_value = localize(locale, start_in_zone, complete_interval_format(locale, start_in_zone, format, granularity), options)
          end_value = localize(locale, end_in_zone, complete_interval_format(locale, end_in_zone, format, granularity), options)
          parts = [
            { :source => :start, :value => start_value },
            { :source => :end, :value => end_value }
          ]
          interval_result("#{start_value}#{separator}#{end_value}", start_object, end_object, parts, options)
        end

        def complete_interval_format(locale, object, format, granularity)
          return format unless granularity == :zone

          type = object.respond_to?(:sec) ? 'time' : 'date'
          resolved = if format.is_a?(Symbol)
            catch(:exception) do
              result = I18n.t(:"#{type}.formats.#{format}", :locale => locale, :throw => true, :skip_interpolation => true)
              result if result.is_a?(String)
            end
          else
            format
          end
          resolved ||= object.respond_to?(:sec) ? "%Y-%m-%d %H:%M:%S %z" : "%Y-%m-%d"
          ensure_interval_offset(resolved, :start, granularity)
        end

        def interval_result(value, start_object, end_object, parts, options)
          return value unless options[:parts] || options[:fragments] || options[:with_parts] || options[:return] == :parts

          I18n::LocalizedInterval.new(value, start_object, end_object, parts)
        end

        def eager_loaded?
          @eager_loaded ||= false
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
