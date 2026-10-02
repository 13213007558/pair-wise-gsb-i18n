# frozen_string_literal: true

module I18n
  class AgreementConflict < ArgumentError
    attr_reader :agreement_features, :features, :conflicting_fragments

    def initialize(message, agreement_features:, features:, conflicting_fragments:)
      @agreement_features = agreement_features
      @features = features
      @conflicting_fragments = conflicting_fragments
      super(message)
    end
  end

  class AmbiguousAgreement < ArgumentError
    attr_reader :combinations, :default_features

    def initialize(message, combinations:, default_features:)
      @combinations = combinations
      @default_features = default_features
      super(message)
    end
  end

  class InvalidAgreement < ArgumentError
  end

  module Agreement
    class Message
      class Candidate
        attr_reader :value, :features

        def initialize(value, features)
          @value = value
          @features = features.freeze
        end

        def compatible_with?(other, features)
          features.all? do |feature|
            next true unless @features.key?(feature) && other.features.key?(feature)
            @features[feature] == other.features[feature]
          end
        end

        def satisfies?(features)
          features.all? do |feature, value|
            !@features.key?(feature) || @features[feature] == value
          end
        end
      end

      class Fragment
        attr_reader :name, :candidates

        def initialize(name, definition, agreement_features)
          @name = name
          raise InvalidAgreement, "agreement fragment #{name.inspect} must be a Hash" unless definition.is_a?(Hash)

          definition = symbolize_keys(definition)
          fixed_features = normalize_features(definition.delete(:features) || {})
          forms = definition.delete(:forms)
          unless definition.empty?
            raise InvalidAgreement, "unknown agreement fragment keys #{definition.keys.map(&:inspect).join(', ')} for #{name.inspect}"
          end
          raise InvalidAgreement, "agreement fragment #{name.inspect} must declare forms" if forms.nil?

          @candidates = form_definitions(forms).flat_map do |form|
            build_candidates(form, fixed_features, agreement_features)
          end.uniq { |candidate| [candidate.value, candidate.features] }.freeze

          raise InvalidAgreement, "agreement fragment #{name.inspect} has no forms" if @candidates.empty?
        end

        def candidates_for(features)
          candidates.select { |candidate| candidate.satisfies?(features) }
        end

        private

        def form_definitions(forms)
          case forms
          when Array
            forms
          when Hash
            symbolized_forms = symbolize_keys(forms)
            if symbolized_forms.key?(:value)
              [symbolized_forms]
            else
              forms.map do |value, definition|
                definition = symbolize_keys(definition) if definition.is_a?(Hash)
                definition.is_a?(Hash) && definition.key?(:value) ? definition : { :value => value, :features => definition }
              end
            end
          else
            [forms]
          end
        end

        def build_candidates(form, fixed_features, agreement_features)
          form = { :value => form } unless form.is_a?(Hash)
          form = symbolize_keys(form)
          value = form.delete(:value)
          feature_data = form.delete(:features) || {}
          feature_sets = feature_data.is_a?(Array) ? feature_data : [feature_data]

          if value.nil?
            raise InvalidAgreement, "agreement fragment #{name.inspect} has a form without a value"
          end
          unless form.empty?
            raise InvalidAgreement, "unknown agreement form keys #{form.keys.map(&:inspect).join(', ')} for #{name.inspect}"
          end

          feature_sets.map do |features|
            merged = fixed_features.merge(normalize_features(features))
            unknown = merged.keys - agreement_features
            unless unknown.empty?
              raise InvalidAgreement, "unknown agreement features #{unknown.map(&:inspect).join(', ')} for #{name.inspect}"
            end
            Candidate.new(value, merged)
          end
        end

        def normalize_features(features)
          unless features.is_a?(Hash)
            raise InvalidAgreement, "agreement features for #{name.inspect} must be a Hash"
          end
          symbolize_keys(features)
        end

        def symbolize_keys(hash)
          hash.each_with_object({}) do |(key, value), result|
            result[key.to_sym] = value
          end
        end
      end

      attr_reader :template, :features, :fragments, :default_features

      def initialize(template:, fragments:, features:, default_features: nil)
        raise InvalidAgreement, "agreement template must be a String" unless template.is_a?(String)

        @template = template
        @features = Array(features).map(&:to_sym).freeze
        raise InvalidAgreement, "agreement message must declare features" if @features.empty?

        @default_features = array_wrap(default_features).map { |defaults| normalize_features(defaults) }.freeze
        unless fragments.is_a?(Hash) && !fragments.empty?
          raise InvalidAgreement, "agreement message must declare fragments"
        end

        @fragments = symbolize_keys(fragments).each_with_object({}) do |(name, definition), result|
          result[name] = Fragment.new(name, definition, @features)
        end.freeze
        validate_template_fragments
        validate_default_features
      end

      def resolve(caller_features = EMPTY_HASH, values = EMPTY_HASH)
        assignment = solve(normalize_features(caller_features))
        selected = assignment.transform_values { |candidate| candidate.value }
        I18n.interpolate(template, values.merge(selected))
      end
      alias_method :i18n_agreement_resolve, :resolve

      private

      def solve(caller_features)
        unknown = caller_features.keys - features
        unless unknown.empty?
          raise InvalidAgreement, "unknown caller agreement features #{unknown.map(&:inspect).join(', ')}"
        end

        domains = fragments.to_h do |name, fragment|
          [name, fragment.candidates_for(caller_features)]
        end
        solutions = search(domains).uniq { |solution| solution[:assignment] }

        if solutions.empty?
          conflicting_fragments = minimal_conflicts(domains)
          raise AgreementConflict.new(
            conflict_message(caller_features, conflicting_fragments),
            :agreement_features => features,
            :features => caller_features,
            :conflicting_fragments => conflicting_fragments
          )
        end

        select_solution(solutions)[:assignment]
      end

      def search(domains, assignment = {})
        return [build_solution(assignment)] if assignment.size == domains.size

        name = next_fragment(domains, assignment)
        domains[name].filter_map do |candidate|
          next unless compatible_assignment?(candidate, assignment)
          search(domains, assignment.merge(name => candidate))
        end.flatten(1)
      end

      def compatible_assignment?(candidate, assignment)
        assignment.all? do |_name, selected|
          candidate.compatible_with?(selected, features)
        end
      end

      def next_fragment(domains, assignment)
        domains.keys.reject { |name| assignment.key?(name) }.min_by do |name|
          domains[name].count { |candidate| compatible_assignment?(candidate, assignment) }
        end
      end

      def build_solution(assignment)
        shared_features = {}
        features.each do |feature|
          values = assignment.values.filter_map do |candidate|
            candidate.features[feature] if candidate.features.key?(feature)
          end.uniq
          shared_features[feature] = values.first if values.one?
        end

        {
          :assignment => assignment,
          :features => shared_features,
          :fragments => assignment.transform_values(&:value)
        }
      end

      def select_solution(solutions)
        candidates = solutions.dup

        default_features.each do |defaults|
          matching = candidates.select do |solution|
            defaults.all? { |feature, value| solution[:features][feature] == value }
          end
          candidates = matching unless matching.empty?
        end

        return candidates.first if candidates.one?

        raise AmbiguousAgreement.new(
          "ambiguous agreement for #{candidates.map { |solution| solution[:features] }.inspect}",
          :combinations => candidates.map { |solution| solution.slice(:features, :fragments) },
          :default_features => default_features
        )
      end

      def minimal_conflicts(domains)
        names = domains.keys
        (1..names.size).each do |size|
          conflicts = names.combination(size).select do |combination|
            search(combination.to_h { |name| [name, domains[name]] }).empty?
          end
          return conflicts unless conflicts.empty?
        end
        []
      end

      def conflict_message(caller_features, conflicting_fragments)
        "no compatible agreement for fragments #{conflicting_fragments.inspect}; caller features are #{caller_features.inspect} and #{features.inspect} must agree"
      end

      def validate_template_fragments
        used = template.scan(/(?<!%)%\{([\w|]+)\}/).flatten.map(&:to_sym).uniq
        unused = fragments.keys - used
        reserved = used & I18n::RESERVED_KEYS
        reserved |= used & [:agreement_features]

        unless reserved.empty?
          raise InvalidAgreement, "agreement fragments cannot use reserved keys #{reserved.map(&:inspect).join(', ')}"
        end
        unless unused.empty?
          raise InvalidAgreement, "agreement fragments are not used by the template: #{unused.map(&:inspect).join(', ')}"
        end
      end

      def validate_default_features
        default_features.each do |defaults|
          unknown = defaults.keys - features
          next if unknown.empty?

          raise InvalidAgreement, "unknown agreement default features #{unknown.map(&:inspect).join(', ')}"
        end
      end

      def normalize_features(features)
        unless features.is_a?(Hash)
          raise InvalidAgreement, "agreement features must be a Hash, got #{features.class}"
        end
        symbolize_keys(features)
      end

      def array_wrap(value)
        return [] if value.nil?
        value.is_a?(Array) ? value : [value]
      end

      def symbolize_keys(hash)
        hash.each_with_object({}) do |(key, value), result|
          result[key.to_sym] = value
        end
      end
    end
  end
end
