# frozen_string_literal: true

# I18n Agreement is useful when a translation is composed of several
# fragments (segments) whose word forms must agree on grammatical features
# such as gender, number or case.
#
# To enable agreement messages you can simply include the Agreement module
# to the Simple backend - or whatever other backend you are using.
#
#   I18n::Backend::Simple.include(I18n::Backend::Agreement)
#
# An agreement message is a translation entry of the form:
#
#   {
#     :agreement => {
#       :on       => [:gender, :number],      # features that must agree
#       :default  => { :number => :singular }, # optional disambiguation rule
#       :template => "%{subject} %{verb}",     # interpolation template
#       :segments => {
#         :subject => {
#           :forms => [
#             { :features => { :gender => :masculine, :number => :singular }, :text => "der Hund" },
#             { :features => { :gender => :feminine,  :number => :singular }, :text => "die Katze" }
#           ]
#         },
#         :verb => "ist" # an invariant segment can be given as a plain String
#       }
#     }
#   }
#
# The legal feature combinations of the whole message are solved before any
# form is chosen, so a segment may narrow down the choices of the others and
# combinations that are only pairwise (but not globally) compatible are
# rejected.
#
# Features given by the caller are hard constraints:
#
#   I18n.t(:sentence, :agreement => { :gender => :feminine })
#
# When no combination satisfies all segments and constraints an
# I18n::AgreementConflict is raised naming the conflicting segments. When
# more than one combination remains, the message's :default rule is used to
# pick one; if it does not (or is missing) an I18n::AmbiguousAgreement is
# raised.
module I18n
  module Backend
    module Agreement
      # Resolves an agreement message entry to a single String by solving the
      # legal feature combinations of the message first and choosing word
      # forms afterwards. Non agreement entries are returned unchanged.
      def agree(locale, entry, options)
        return entry unless entry.is_a?(Hash)

        spec = entry[:agreement]
        return entry unless spec.is_a?(Hash) && (spec.key?(:on) || spec.key?(:segments) || spec.key?(:template))

        constraints = agreement_constraints(entry, options)
        on          = agreement_features(entry, spec)
        template    = agreement_template(entry, spec)
        segments    = agreement_segments(entry, spec)
        default     = agreement_default(entry, spec)

        solutions = solve_agreement(segments, on, constraints)

        if solutions.empty?
          raise AgreementConflict.new(conflicting_segments(segments, on, constraints), constraints)
        end

        solutions.uniq! { |solution| solution.values.map { |form| form[:text] } }

        if solutions.size > 1
          solutions = preferred_solutions(solutions, default, on) if default
          raise AmbiguousAgreement.new(solutions.map { |solution| solution_features(solution, on) }) if solutions.size > 1
        end

        interpolate_agreement_template(template, segments.map(&:first), solutions.first)
      end

      protected

      def agreement_constraints(entry, options)
        constraints = options[:agreement] || EMPTY_HASH
        unless constraints.is_a?(Hash)
          raise I18n::ArgumentError.new(":agreement constraints must be a Hash, #{constraints.inspect} given")
        end
        constraints.each_with_object({}) { |(key, value), hash| hash[key.to_sym] = value }
      end

      def agreement_features(entry, spec)
        on = spec[:on]
        unless on.is_a?(Array) && !on.empty?
          raise InvalidAgreementData.new(entry, 'missing the features that must agree, e.g. :on => [:gender]')
        end
        on.map(&:to_sym)
      end

      def agreement_template(entry, spec)
        template = spec[:template]
        raise InvalidAgreementData.new(entry, 'missing :template') unless template.is_a?(String)
        template
      end

      def agreement_default(entry, spec)
        default = spec[:default]
        return nil if default.nil?
        unless default.is_a?(Hash)
          raise InvalidAgreementData.new(entry, ':default must be a Hash of feature => value')
        end
        default.each_with_object({}) { |(key, value), hash| hash[key.to_sym] = value }
      end

      def agreement_segments(entry, spec)
        segments = spec[:segments]
        unless segments.is_a?(Hash) && !segments.empty?
          raise InvalidAgreementData.new(entry, 'missing :segments')
        end

        segments.map do |name, segment|
          [name.to_sym, agreement_forms(entry, name, segment)]
        end
      end

      def agreement_forms(entry, name, segment)
        case segment
        when ::String
          [{ :features => EMPTY_HASH, :text => segment }]
        when ::Hash
          forms = segment[:forms]
          unless forms.is_a?(Array) && !forms.empty?
            raise InvalidAgreementData.new(entry, "segment #{name.inspect} is missing :forms")
          end
          forms.map { |form| agreement_form(entry, name, form) }
        else
          raise InvalidAgreementData.new(entry, "segment #{name.inspect} must be a String or a Hash")
        end
      end

      def agreement_form(entry, name, form)
        case form
        when ::String
          { :features => EMPTY_HASH, :text => form }
        when ::Hash
          text = form[:text]
          unless text.is_a?(::String)
            raise InvalidAgreementData.new(entry, "a form of segment #{name.inspect} is missing :text")
          end
          features = form[:features] || EMPTY_HASH
          unless features.is_a?(::Hash)
            raise InvalidAgreementData.new(entry, "a form of segment #{name.inspect} has invalid :features")
          end
          features = features.each_with_object({}) { |(key, value), hash| hash[key.to_sym] = value }
          { :features => features, :text => text }
        else
          raise InvalidAgreementData.new(entry, "a form of segment #{name.inspect} must be a String or a Hash")
        end
      end

      # Finds all legal combinations of word forms: one form per segment such
      # that all forms agree on the +on+ features and respect the caller
      # +constraints+. Returns an Array of Hashes mapping segment names to
      # the chosen form.
      def solve_agreement(segments, on, constraints)
        solutions  = []
        assignment = {}
        chosen     = {}

        backtrack = lambda do |index|
          if index == segments.size
            solutions << chosen.dup
            next
          end

          name, forms = segments[index]
          forms.each do |form|
            features = form[:features]
            next unless agreement_form_compatible?(features, assignment, constraints)

            assigned = []
            features.each do |feature, value|
              next unless on.include?(feature) && !assignment.key?(feature)
              assignment[feature] = value
              assigned << feature
            end
            chosen[name] = form

            backtrack.call(index + 1)

            assigned.each { |feature| assignment.delete(feature) }
            chosen.delete(name)
          end
        end
        backtrack.call(0)

        solutions
      end

      def agreement_form_compatible?(features, assignment, constraints)
        assignment.all? { |feature, value| !features.key?(feature) || features[feature] == value } &&
          constraints.all? { |feature, value| !features.key?(feature) || features[feature] == value }
      end

      # Computes an irreducible set of segments that cannot agree with each
      # other (given the caller constraints), so the conflict can be reported
      # precisely instead of blaming the whole message.
      def conflicting_segments(segments, on, constraints)
        core = segments.map(&:first)
        segments.each do |name, _forms|
          trial = core - [name]
          next if trial.empty?
          trial_segments = segments.select { |segment_name, _| trial.include?(segment_name) }
          core = trial if solve_agreement(trial_segments, on, constraints).empty?
        end
        core
      end

      def preferred_solutions(solutions, default, on)
        preferred = solutions.select do |solution|
          features = solution_features(solution, on)
          default.all? { |feature, value| features[feature] == value }
        end
        preferred.empty? ? solutions : preferred
      end

      def solution_features(solution, on)
        features = solution.values.each_with_object({}) { |form, hash| hash.merge!(form[:features]) }
        on.each_with_object({}) { |feature, hash| hash[feature] = features[feature] }
      end

      def interpolate_agreement_template(template, names, solution)
        template.gsub(/%\{(\w+)\}/) do |match|
          name = Regexp.last_match(1).to_sym
          names.include?(name) && solution[name] ? solution[name][:text] : match
        end
      end
    end
  end
end
