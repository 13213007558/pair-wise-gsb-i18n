# frozen_string_literal: true

module I18n
  class LocalizedInterval < String
    attr_reader :start_object, :end_object, :parts

    def initialize(value, start_object, end_object, parts)
      super(value)
      @start_object = start_object
      @end_object = end_object
      @parts = parts
    end

    def start
      fragment(:start)
    end

    def finish
      fragment(:end)
    end
    alias_method :end, :finish

    def shared
      values = parts.select { |part| part[:source] == :shared && part[:role] != :separator }.map { |part| part[:value] }
      values.empty? ? nil : values.join
    end

    def [](source)
      fragment(source)
    end

    def to_a
      parts.map(&:dup)
    end

    def each(&block)
      parts.each(&block)
    end

    def to_h
      {
        :start => start,
        :end => finish,
        :shared => shared,
        :parts => parts
      }
    end

    private

      def fragment(source)
        parts.select { |part| part[:source] == source && part[:role] != :separator }.map { |part| part[:value] }.join
      end
  end
end
