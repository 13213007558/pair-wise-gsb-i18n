# frozen_string_literal: true

module I18n
  module Gettext
    # Parses and evaluates the +Plural-Forms+ header of a Gettext PO file,
    # e.g.:
    #
    #   Plural-Forms: nplurals=3; plural=n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2;
    #
    # The +plural+ expression is a subset of C expressions over the integer
    # variable +n+ (the count). It is parsed into an AST and evaluated
    # directly - no Ruby code is ever +eval+-ed. Supported features:
    #
    # * integer literals and the variable +n+
    # * arithmetic: <tt>+ - * / % << >></tt> and unary <tt>+ - ~</tt>
    # * comparison: <tt>== != < > <= >=</tt> (yield 1 or 0, like C)
    # * logic: <tt>! && ||</tt> with short-circuit semantics
    # * the ternary conditional <tt>cond ? a : b</tt>
    # * parentheses
    #
    # Division and modulo use C semantics (truncation towards zero) and
    # raise DivisionByZero on a zero divisor. Results of #call are
    # guaranteed to be a valid msgstr index, i.e. an Integer within
    # <tt>0...nplurals</tt>, otherwise InvalidIndex is raised.
    class PluralForms
      Error           = Class.new(StandardError)
      SyntaxError     = Class.new(Error)
      EvaluationError = Class.new(Error)
      DivisionByZero  = Class.new(EvaluationError)
      InvalidIndex    = Class.new(EvaluationError)

      # Raised when two PO files for the same locale declare different
      # Plural-Forms rules and the conflict strategy is :raise.
      ConflictingRules = Class.new(Error)

      # Raised when the number of msgstr[n] values of an entry does not
      # match the nplurals declared by the Plural-Forms header.
      PluralCountMismatch = Class.new(Error)

      # Binary operators grouped by precedence, lowest first (C precedence).
      BINARY_OPERATOR_LEVELS = [
        ['||'],
        ['&&'],
        ['|'],
        ['^'],
        ['&'],
        ['==', '!='],
        ['<', '>', '<=', '>='],
        ['<<', '>>'],
        ['+', '-'],
        ['*', '/', '%']
      ].freeze

      UNARY_OPERATORS = ['!', '-', '+', '~'].freeze

      MULTI_CHAR_OPERATORS = ['||', '&&', '==', '!=', '<=', '>=', '<<', '>>'].freeze
      SINGLE_CHAR_OPERATORS = ['-', '+', '*', '/', '%', '(', ')', '<', '>', '!', '~', '?', ':', '&', '^', '|'].freeze

      attr_reader :nplurals, :expression, :location

      # Parses the value of a +Plural-Forms+ header (the part after
      # "Plural-Forms:"), e.g. "nplurals=2; plural=(n != 1);".
      # +location+ is included in error messages to help locate the
      # offending file/entry.
      def self.parse(header, location = nil)
        unless header =~ /\bnplurals\s*=\s*(\d+)/
          raise SyntaxError, "#{location_prefix(location)}missing nplurals=... in Plural-Forms header #{header.inspect}"
        end
        nplurals = $1.to_i

        unless header =~ /\bplural\s*=\s*([^;]+)/
          raise SyntaxError, "#{location_prefix(location)}missing plural=... in Plural-Forms header #{header.inspect}"
        end
        expression = $1

        new(nplurals, expression, location)
      end

      def self.location_prefix(location)
        location ? "#{location}: " : ""
      end

      def initialize(nplurals, expression, location = nil)
        @nplurals = nplurals
        @expression = expression.to_s.strip
        @location = location

        if @nplurals < 1
          raise SyntaxError, "#{location_prefix}nplurals must be >= 1, got #{@nplurals}"
        end

        @ast = Parser.new(@expression, @location).parse
      end

      # Returns the msgstr index for the given count.
      def call(count)
        n = coerce_count(count)
        index = evaluate(@ast, n)

        unless index.is_a?(Integer) && index >= 0 && index < nplurals
          raise InvalidIndex, "#{location_prefix}Plural-Forms expression #{expression.inspect} " \
            "returned #{index.inspect} for n=#{n}, but nplurals is #{nplurals} (valid index range: 0...#{nplurals})"
        end

        index
      end

      def ==(other)
        other.is_a?(PluralForms) &&
          nplurals == other.nplurals &&
          normalized_expression == other.normalized_expression
      end
      alias eql? ==

      def hash
        [nplurals, normalized_expression].hash
      end

      protected

      def normalized_expression
        expression.gsub(/\s+/, '')
      end

      private

      def location_prefix
        self.class.location_prefix(@location)
      end

      def coerce_count(count)
        Integer(count)
      rescue ::ArgumentError, ::TypeError
        raise EvaluationError, "#{location_prefix}count #{count.inspect} cannot be used as an integer " \
          "in Plural-Forms expression #{expression.inspect}"
      end

      def evaluate(node, n)
        case node[0]
        when :num
          node[1]
        when :n
          n
        when :unary
          evaluate_unary(node[1], evaluate(node[2], n))
        when :binary
          evaluate_binary(node, n)
        when :ternary
          evaluate(node[1], n) != 0 ? evaluate(node[2], n) : evaluate(node[3], n)
        end
      end

      def evaluate_unary(operator, value)
        case operator
        when '!' then value.zero? ? 1 : 0
        when '-' then -value
        when '+' then value
        when '~' then ~value
        end
      end

      def evaluate_binary(node, n)
        operator = node[1]

        case operator
        when '&&'
          evaluate(node[2], n) != 0 ? (evaluate(node[3], n) != 0 ? 1 : 0) : 0
        when '||'
          evaluate(node[2], n) != 0 ? 1 : (evaluate(node[3], n) != 0 ? 1 : 0)
        else
          left  = evaluate(node[2], n)
          right = evaluate(node[3], n)
          evaluate_arithmetic(operator, left, right, n)
        end
      end

      def evaluate_arithmetic(operator, left, right, n)
        case operator
        when '+'  then left + right
        when '-'  then left - right
        when '*'  then left * right
        when '/'  then divide(left, right, n)
        when '%'  then left - divide(left, right, n) * right
        when '<<' then left << right
        when '>>' then left >> right
        when '&'  then left & right
        when '|'  then left | right
        when '^'  then left ^ right
        when '==' then left == right ? 1 : 0
        when '!=' then left != right ? 1 : 0
        when '<'  then left <  right ? 1 : 0
        when '<=' then left <= right ? 1 : 0
        when '>'  then left >  right ? 1 : 0
        when '>=' then left >= right ? 1 : 0
        end
      end

      # C semantics: integer division truncates towards zero.
      def divide(left, right, n)
        check_divisor(right, n)
        quotient = left.abs / right.abs
        left.negative? != right.negative? ? -quotient : quotient
      end

      def check_divisor(right, n)
        return unless right.zero?

        raise DivisionByZero, "#{location_prefix}division by zero in Plural-Forms expression " \
          "#{expression.inspect} (n=#{n})"
      end

      # Recursive descent parser for the C-like plural expression grammar.
      class Parser
        Token = Struct.new(:type, :value, :position)

        def initialize(source, location = nil)
          @source = source
          @location = location
          @tokens = tokenize(source)
          @pos = 0
        end

        def parse
          if @tokens.empty?
            raise syntax_error("empty plural expression", 0)
          end

          ast = parse_ternary

          if (token = current_token)
            raise syntax_error("unexpected #{token.value.inspect}", token.position)
          end

          ast
        end

        private

        def tokenize(source)
          tokens = []
          rest = source
          position = 0

          until rest.empty?
            case rest
            when /\A\s+/
              # skip whitespace
            when /\A(\d+)/
              tokens << Token.new(:num, $1.to_i, position)
            when /\A(n)\b/
              tokens << Token.new(:n, 'n', position)
            when /\A(#{MULTI_CHAR_OPERATORS.map { |op| Regexp.escape(op) }.join('|')})/
              tokens << Token.new(:op, $1, position)
            when /\A(#{SINGLE_CHAR_OPERATORS.map { |op| Regexp.escape(op) }.join('|')})/
              tokens << Token.new(:op, $1, position)
            else
              raise syntax_error("unexpected character #{rest[0].inspect}", position)
            end

            consumed = $&.length
            position += consumed
            rest = rest[consumed..-1]
          end

          tokens
        end

        def parse_ternary
          condition = parse_binary(0)
          return condition unless accept_op?('?')

          when_true = parse_ternary
          expect_op!(':')
          when_false = parse_ternary
          [:ternary, condition, when_true, when_false]
        end

        def parse_binary(level)
          return parse_unary if level >= BINARY_OPERATOR_LEVELS.length

          left = parse_binary(level + 1)

          while (token = current_token) && token.type == :op && BINARY_OPERATOR_LEVELS[level].include?(token.value)
            advance
            right = parse_binary(level + 1)
            left = [:binary, token.value, left, right]
          end

          left
        end

        def parse_unary
          token = current_token

          if token && token.type == :op && UNARY_OPERATORS.include?(token.value)
            advance
            [:unary, token.value, parse_unary]
          else
            parse_primary
          end
        end

        def parse_primary
          token = current_token

          if token.nil?
            raise syntax_error("unexpected end of expression", @source.length)
          end

          case token.type
          when :num
            advance
            [:num, token.value]
          when :n
            advance
            [:n]
          else
            if token.value == '('
              advance
              ast = parse_ternary
              expect_op!(')')
              ast
            else
              raise syntax_error("unexpected #{token.value.inspect}", token.position)
            end
          end
        end

        def current_token
          @tokens[@pos]
        end

        def advance
          @pos += 1
        end

        def accept_op?(operator)
          token = current_token
          return false unless token && token.type == :op && token.value == operator

          advance
          true
        end

        def expect_op!(operator)
          return if accept_op?(operator)

          token = current_token
          found = token ? token.value.inspect : "end of expression"
          position = token ? token.position : @source.length
          raise syntax_error("expected #{operator.inspect} but found #{found}", position)
        end

        def syntax_error(message, position)
          location = PluralForms.location_prefix(@location)
          SyntaxError.new("#{location}syntax error in Plural-Forms expression #{@source.inspect}: " \
            "#{message} (at position #{position})")
        end
      end
    end
  end
end
