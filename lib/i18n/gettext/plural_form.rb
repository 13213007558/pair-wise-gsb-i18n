# frozen_string_literal: true

module I18n
  module Gettext
    class PluralForm
      class Error < ArgumentError
      end

      class ParseError < Error
        attr_reader :source, :position

        def initialize(message, source, position)
          @source = source
          @position = position
          super("#{message} in plural expression #{source.inspect} at position #{position}")
        end
      end

      class EvaluationError < Error
      end

      class ResultOutOfRange < Error
      end

      attr_reader :nplurals, :expression, :filename

      def self.parse(header, filename: nil)
        raise Error, "Plural-Forms header is missing" if header.nil? || header.empty?

        nplurals = header[/\bnplurals\s*=\s*([^;\n]+)/i, 1]
        expression = header[/\bplural\s*=\s*([^;\n]+)(?:;\s*)?\z/im, 1]

        raise Error, "nplurals is missing from Plural-Forms header #{header.inspect}" if nplurals.nil?
        raise Error, "plural expression is missing from Plural-Forms header #{header.inspect}" if expression.nil?

        nplurals = nplurals.strip
        raise Error, "nplurals must be a positive integer, got #{nplurals.inspect}" unless nplurals.match?(/\A[0-9]+\z/)

        nplurals = nplurals.to_i
        raise Error, "nplurals must be a positive integer, got #{nplurals.inspect}" if nplurals <= 0

        expression = expression.strip
        ast = Parser.new(expression).parse
        new(nplurals, expression, ast, filename: filename)
      end

      def initialize(nplurals, expression, ast, filename: nil)
        @nplurals = nplurals
        @expression = expression
        @ast = ast
        @filename = filename
      end

      def call(count)
        index = evaluate(count)

        unless index.is_a?(::Integer) && index >= 0 && index < nplurals
          raise ResultOutOfRange, location("plural expression returned #{index.inspect} for count #{count.inspect}; expected an integer in 0...#{nplurals}")
        end

        index
      end
      alias_method :[], :call

      def ==(other)
        other.is_a?(self.class) &&
          nplurals == other.nplurals &&
          canonical_ast == other.canonical_ast
      end
      alias_method :eql?, :==

      def hash
        [nplurals, canonical_ast].hash
      end

      def inspect
        "#<#{self.class.name} nplurals=#{nplurals} plural=#{expression.inspect}>"
      end

      protected

      attr_reader :ast

      def canonical_ast
        @canonical_ast ||= canonical_node(ast)
      end

      def canonical_node(node)
        operation = node.first
        children = node[1...-1].map do |child|
          child.is_a?(::Array) ? canonical_node(child) : child
        end
        [operation, *children]
      end

      private

      def evaluate(count)
        integer_count = count.is_a?(::Integer) ? count : convert_count(count)
        Evaluator.new(self, integer_count).evaluate(ast)
      rescue ZeroDivisionError
        raise EvaluationError, location("division by zero in plural expression #{expression.inspect} for count #{count.inspect}")
      end

      def convert_count(count)
        if count.is_a?(::Numeric) && count == count.to_int
          count.to_int
        else
          raise EvaluationError, location("plural count must be an integer, got #{count.inspect}")
        end
      rescue NoMethodError
        raise EvaluationError, location("plural count must be an integer, got #{count.inspect}")
      end

      def location(message)
        filename ? "#{filename}: #{message}" : message
      end

      class Parser
        TOKEN_PATTERN = %r{\A\s*(?:(\d+)|(n)|(<=|>=|==|!=|&&|\|\|)|([+\-*/%<>!?:()]))}

        def initialize(source)
          @source = source
          @tokens = tokenize
          @position = 0
        end

        def parse
          ast = expression
          unless at_end?
            token = current
            raise ParseError.new("unexpected token #{token[:value].inspect}", source, token[:start])
          end
          ast
        end

        private

        def tokenize
          tokens = []
          string = source
          offset = 0

          until string.empty?
            match = string.match(TOKEN_PATTERN)
            unless match
              position = offset + string.index(/\S/) if string.match?(/\S/)
              raise ParseError.new("unexpected character", source, position || offset)
            end

            start = offset + match.begin(0) + (match[0] =~ /\S/)
            value = match[1] || match[2] || match[3] || match[4]
            type = match[1] ? :number : match[2] ? :n : :operator
            tokens << { type: type, value: value, start: start }

            consumed = match[0].length
            offset += consumed
            string = string[consumed..]
          end

          tokens
        end

        def expression(min_binding_power = 0)
          left = parse_prefix

          while infix_operator?(current_value) && infix_binding_power(current_value) >= min_binding_power
            operator = advance

            if operator[:value] == "?"
              binding_power = infix_binding_power("?")
              true_value = expression(binding_power + 1)
              expect!(":", operator[:start] + 1)
              false_value = expression(binding_power)
              left = [:ternary, left, true_value, false_value, operator[:start]]
            else
              binding_power = infix_binding_power(operator[:value])
              right = expression(binding_power + 1)
              operation = { "&&" => :and, "||" => :or }.fetch(operator[:value], operator[:value].to_sym)
              left = [operation, left, right, operator[:start]]
            end
          end

          left
        end

        def parse_prefix
          if operator?("-") || operator?("+") || operator?("!")
            operator = advance
            operand = expression(prefix_binding_power)
            return [:negate, operand, operator[:start]] if operator[:value] == "-"
            return [:not, operand, operator[:start]] if operator[:value] == "!"
            return operand
          end

          parse_primary
        end

        def parse_primary
          token = current

          case token[:type]
          when :number
            advance
            [:number, token[:value].to_i, token[:start]]
          when :n
            advance
            [:n, token[:start]]
          else
            if operator?("(")
              advance
              ast = expression
              expect!(")", token[:start] + 1)
              ast
            else
              raise ParseError.new("unexpected token #{token[:value].inspect}", source, token[:start])
            end
          end
        end

        def operator?(value)
          current[:type] == :operator && current[:value] == value
        end

        def infix_operator?(value)
          infix_binding_powers.key?(value)
        end

        def infix_binding_power(operator)
          infix_binding_powers.fetch(operator, 0)
        end

        def infix_binding_powers
          {
            "?" => 2,
            "||" => 4,
            "&&" => 8,
            "==" => 12,
            "!=" => 12,
            "<" => 16,
            ">" => 16,
            "<=" => 16,
            ">=" => 16,
            "+" => 20,
            "-" => 20,
            "*" => 24,
            "/" => 24,
            "%" => 24
          }
        end

        def prefix_binding_power
          26
        end

        def current
          tokens[position] || { type: :end, value: nil, start: source.length }
        end

        def current_value
          current[:value]
        end

        def advance
          token = current
          @position += 1 unless at_end?
          token
        end

        def expect!(value, position)
          return advance if operator?(value)

          token = current
          raise ParseError.new("expected #{value.inspect}, got #{token[:value].inspect}", source, position)
        end

        def at_end?
          position >= tokens.size
        end

        attr_reader :source, :tokens

        def position
          @position
        end
      end

      class Evaluator
        def initialize(plural_form, count)
          @plural_form = plural_form
          @count = count
        end

        def evaluate(node)
          operation, left, right, position = node

          case operation
          when :number
            left
          when :n
            @count
          when :negate
            -integer(left, position)
          when :not
            evaluate(left).zero? ? 1 : 0
          when :and
            evaluate(left).zero? ? 0 : (evaluate(right).zero? ? 0 : 1)
          when :or
            evaluate(left).zero? ? (evaluate(right).zero? ? 0 : 1) : 1
          when :ternary
            evaluate(left).zero? ? evaluate(node[3]) : evaluate(right)
          else
            evaluate_binary(operation, left, right, position)
          end
        end

        private

        def evaluate_binary(operation, left_node, right_node, position)
          left = integer(left_node, position)
          right = integer(right_node, position)

          if right.zero? && [:/, :%].include?(operation)
            raise EvaluationError, @plural_form.send(:location, "division by zero in plural expression #{@plural_form.expression.inspect} for count #{@count.inspect} at position #{position}")
          end

          case operation
          when :+ then left + right
          when :- then left - right
          when :* then left * right
          when :/ then truncate(left, right)
          when :% then truncate_modulo(left, right)
          when :< then boolean(left < right)
          when :> then boolean(left > right)
          when :<= then boolean(left <= right)
          when :>= then boolean(left >= right)
          when :== then boolean(left == right)
          when :!= then boolean(left != right)
          else
            raise EvaluationError, @plural_form.send(:location, "unsupported operator #{operation.inspect} at position #{position}")
          end
        end

        def integer(node, _position)
          value = evaluate(node)
          return value if value.is_a?(::Integer)

          raise EvaluationError, @plural_form.send(:location, "plural expression produced non-integer #{value.inspect}")
        end

        def truncate(left, right)
          value = left.to_r / right
          value >= 0 ? value.floor : value.ceil
        end

        def truncate_modulo(left, right)
          left - (truncate(left, right) * right)
        end

        def boolean(value)
          value ? 1 : 0
        end
      end
    end
  end
end
