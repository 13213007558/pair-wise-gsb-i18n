# frozen_string_literal: true

require 'i18n'

module I18n
  module Backend
    # A read-only, *static* checker for translation Symbol aliases (links).
    #
    # Translation values that are Symbols are treated as links to other
    # (absolute) keys by I18n (see I18n::Backend::Base#resolve). Links are
    # followed lazily at lookup time, so problems tend to reach production:
    #
    #   * links can form infinite +cycles+ (at runtime the call stack simply
    #     overflows);
    #   * links can point at keys that do not exist (+dangling+ references);
    #   * links can ultimately resolve to values of an unexpected +type+
    #     (a Proc, an Array, ...).
    #
    # Cycles are especially easy to miss because every individual file can
    # look fine: the cycle only closes once a query crosses two different
    # backends of the backend chain (and possibly locale fallbacks).
    #
    # The checker loads files/directories into throwaway in-memory data and
    # simulates a real query faithfully:
    #
    #   * *backend priority* -- like I18n::Backend::Chain, backends are tried
    #     in order and namespace Hashes are deep-merged with the leftmost
    #     (highest priority) backend winning on conflicts;
    #   * *scope* -- a link is always an ABSOLUTE key (Simple#lookup resolves
    #     Symbol segments with +scope: nil+); mid-path links restart a full
    #     lookup and the remaining segments then descend locally;
    #   * *locale fallback order* -- as computed by I18n::Locale::Fallbacks.
    #     In the standard setup the Chain's member backends include the
    #     Fallbacks module (e.g. Rails' ActiveRecord + Simple chain), so within
    #     one Chain lookup the order is backend-first: backend 1 tries every
    #     fallback locale, then backend 2, etc. Every alias hop restarts from
    #     the ORIGINAL requested locale with its full fallback chain (as
    #     Fallbacks#resolve_entry sets +fallback_original_locale+).
    #
    # Dynamic values (Proc/lambda) are reported as +:dynamic+; they are never
    # called, so no conclusion about their eventual result is fabricated.
    #
    # No global I18n state is read for configuration or mutated: I18n.backend,
    # I18n.config, I18n.load_path, the I18n.fallbacks global and translation
    # caches are never touched.
    class AliasChecker
      # One step in an alias resolution chain.
      Hop = Struct.new(:index, :backend, :locale, :key, :kind, keyword_init: true) do
        def to_s
          source = backend ? "backend=#{backend} " : ''
          "#{index}. #{source}locale=#{locale} key=#{key} [#{kind}]"
        end
      end

      # Resolution of one alias from one requested locale.
      # status: :ok | :cycle | :dangling | :dynamic
      Result = Struct.new(
        :alias_key, :locale, :status, :terminal_type, :terminal_file,
        :hops, :ring, keyword_init: true
      )

      # An alias discovered in the data, with a Result per queried locale.
      Finding = Struct.new(:alias_key, :declared_in, :results, keyword_init: true)

      attr_reader :backends, :fallback_order, :query_locales, :separator

      # @param backend_dirs [Array<Array<String>>] ordered backend groups; each
      #   group is a list of files/directories merged into one backend with
      #   Simple's deep-merge semantics.
      # @param fallback_mapping [Hash, nil] explicit Fallbacks mappings
      #   (e.g. +{ :"de-AT" => :de }+)
      # @param default_locales [Array<Symbol>] default fallback locales
      # @param query_locales [Array<Symbol>, nil] locales every alias is
      #   checked from; defaults to all locales present in the data
      # @param fallbacks [Boolean] whether member backends apply locale
      #   fallbacks (default true; false restricts every query to its locale)
      # @param separator [String, nil] key separator (default ".")
      def initialize(backend_dirs:, fallback_mapping: nil, default_locales: [:en],
                     query_locales: nil, fallbacks: true, separator: nil)
        @separator = separator || '.'
        @loader = Loader.new

        @fallback_computer = I18n::Locale::Fallbacks.new
        @fallback_computer.defaults = Array(default_locales)
        @fallback_computer.map(fallback_mapping) if fallback_mapping
        @fallbacks_enabled = fallbacks

        @backends = backend_dirs.each_with_index.map do |paths, index|
          data, sources = @loader.load(paths)
          { index: index, data: data, sources: sources }
        end

        @query_locales = Array(query_locales).map(&:to_sym)
        @query_locales = data_locales if @query_locales.empty?
        @fallback_order = @query_locales.to_h do |locale|
          order = @fallbacks_enabled ? @fallback_computer[locale] : [locale]
          [locale, order]
        end
      end

      # Runs the full check. @return [Array<Finding>]
      def check
        scan_aliases.map do |entry|
          results = @query_locales.map do |locale|
            resolve_alias(entry[:key], locale)
          end
          Finding.new(
            alias_key: entry[:key],
            declared_in: entry[:files],
            results: results
          )
        end
      end

      # True when no cycle or dangling link was found from any queried locale.
      def healthy?
        check.none? do |finding|
          finding.results.any? { |result| %i[cycle dangling].include?(result.status) }
        end
      end

      private

      def data_locales
        @backends.flat_map { |backend| backend[:data].keys }.uniq
      end

      # Collects every Symbol value I18n follows as a link. Symbols inside
      # Arrays are pluralization data and are never followed.
      def scan_aliases
        found = {}
        @backends.each do |backend|
          backend[:data].each do |locale, tree|
            sources = backend[:sources][locale] || {}
            walk(tree, sources) do |key, file|
              found[key] ||= { key: key, files: [] }
              found[key][:files] << file
              found[key][:files].uniq!
            end
          end
        end
        found.values
      end

      def walk(node, source_node, path = [], &block)
        return unless node.is_a?(Hash)

        node.each do |segment, child|
          current = path + [segment]
          if child.is_a?(Symbol)
            yield(current.join(@separator), source_node[segment])
          elsif child.is_a?(Hash)
            child_sources = source_node.is_a?(Hash) ? (source_node[segment] || {}) : {}
            walk(child, child_sources, current, &block)
          end
        end
      end

      # ---- resolution simulation ----------------------------------------

      def resolve_alias(alias_key, locale)
        hops = []
        entered_at = {} # frame => hops.size when the frame was entered

        status, type, file, = chain_resolve(
          locale, split_key(alias_key), alias_key.to_s, hops, entered_at,
          original_locale: locale, leaf: true
        )

        ring = nil
        if status == :cycle
          start = entered_at[[locale, split_key(alias_key)]] || 0
          ring = hops[start..].map(&:to_s)
        end
        Result.new(
          alias_key: alias_key,
          locale: locale,
          status: status,
          terminal_type: type,
          terminal_file: file,
          hops: hops,
          ring: ring
        )
      end

      # Emulates one I18n.translate call going through a Chain whose member
      # backends include the Fallbacks module (the standard real setup):
      # backend priority is outer, the requested locale's fallback order is
      # inner. A Symbol link is resolved by exactly such a call, so this method
      # is reused for every alias hop (Base#resolve -> I18n.translate).
      #
      # @return [status, terminal_type, source_file, concrete_value, ring]
      #   concrete_value is nil except for :ok (the resolved scalar, or the
      #   merged namespace Hash); ring is set only for :cycle.
      #
      # +original_locale+ is the locale the outer query was issued with: a
      # link always restarts the lookup for THAT locale (cf.
      # Fallbacks#resolve_entry's +fallback_original_locale+), never for the
      # fallback locale currently being tried.
      def chain_resolve(locale, segments, display_key, hops, entered_at,
                        original_locale: nil, leaf: true)
        original_locale ||= locale
        frame = [original_locale, segments]
        if (entry_index = entered_at[frame])
          hops << Hop.new(
            index: hops.size + 1, backend: nil, locale: original_locale,
            key: display_key,
            kind: "CYCLE: already resolving #{original_locale}.#{segments.join(@separator)}"
          )
          start = [entry_index - 1, 0].max
          return [:cycle, nil, nil, nil, hops[start..].map(&:to_s)]
        end
        entered_at[frame] = hops.size

        namespace = nil # accumulated/merged Hash across member backends
        contributing = []

        @backends.each do |backend|
          (@fallback_order[original_locale] || [original_locale]).each do |fallback_locale|
            outcome = lookup_inject(
              backend, fallback_locale, backend[:data][fallback_locale],
              segments, 0, hops, entered_at, original_locale
            )
            next if outcome.nil? # key absent (or explicitly nil) in backend/locale

            status, type, file, value = outcome
            case status
            when :cycle, :dynamic
              return [status, type, file, nil, outcome[4]]
            when :found
              if value.is_a?(Hash)
                namespace = leftmost_merge(namespace, value)
                contributing << "##{backend[:index]}/#{fallback_locale}"
              else
                hops << Hop.new(
                  index: hops.size + 1, backend: "##{backend[:index]}",
                  locale: fallback_locale, key: display_key,
                  kind: leaf ? "terminal #{type}" : 'resolved subtree'
                )
                entered_at.delete(frame)
                return [:ok, type, file, value]
              end
            end
          end
        end

        if namespace
          hops << Hop.new(
            index: hops.size + 1, backend: nil,
            locale: contributing.first.split('/').last,
            key: display_key,
            kind: (leaf ? 'terminal Hash namespace merged from ' : 'namespace merged from ') +
                  contributing.join(', ')
          )
          entered_at.delete(frame)
          return [:ok, :Hash, nil, namespace]
        end

        hops << Hop.new(
          index: hops.size + 1, backend: nil, locale: original_locale,
          key: display_key, kind: 'NOT FOUND (dangling reference)'
        )
        entered_at.delete(frame)
        [:dangling, nil, nil, nil]
      end

      # Emulates Simple#lookup's #inject walk through one backend's data tree
      # (also used to descend inside a subtree a mid-path link resolved to).
      # Symbol segments are resolved as absolute links by a full chain
      # resolution that restarts from the original locale; plain values are
      # descended locally; Proc values are dynamic and never called; an
      # explicit nil behaves like a miss (Chain then tries the next backend).
      #
      # @return nil (absent) | [:found, type, file, value] |
      #   [:dynamic, type, file] | [:cycle, nil, nil, nil, ring]
      def lookup_inject(backend, locale, node, segments, pos, hops,
                        entered_at, original_locale)
        segment = segments[pos]
        return nil unless node.is_a?(Hash) && node.key?(segment)

        value = node[segment]
        file = source_file(backend, locale, segments, pos)
        last = pos == segments.size - 1

        if value.is_a?(Symbol)
          hops << Hop.new(
            index: hops.size + 1, backend: "##{backend[:index]}",
            locale: locale, key: value.to_s,
            kind: (pos.zero? ? 'alias' : 'mid-path alias')
          )

          # A link is absolute and restarts from the ORIGINAL requested
          # locale through the full chain and its fallback order.
          status, type, link_file, resolved, ring = chain_resolve(
            locale, split_key(value), value.to_s, hops, entered_at,
            original_locale: original_locale, leaf: last
          )
          case status
          when :cycle
            [:cycle, nil, nil, nil, ring]
          when :dynamic
            [:dynamic, type, link_file]
          when :dangling
            # resolve_entry returns nil -> Simple#lookup misses in this backend
            nil
          when :ok
            if last
              # Final segment is itself a link: the chain-resolved terminal.
              [:found, type, link_file, resolved]
            else
              # Mid-path link resolved to a subtree: keep injecting locally;
              # Symbol children inside it are absolute links again.
              lookup_inject(
                backend, locale, resolved, segments, pos + 1, hops,
                entered_at, original_locale
              )
            end
          end
        elsif value.is_a?(Proc)
          hops << Hop.new(
            index: hops.size + 1, backend: "##{backend[:index]}",
            locale: locale, key: segments.join(@separator),
            kind: 'dynamic Proc value - cannot be determined statically (not called)'
          )
          [:dynamic, :Proc, file]
        elsif value.nil?
          nil
        elsif last
          [:found, type_name(value), file, value]
        else
          lookup_inject(
            backend, locale, value, segments, pos + 1, hops,
            entered_at, original_locale
          )
        end
      end

      def source_file(backend, locale, segments, pos)
        node = backend[:sources][locale]
        segments[0..pos].each do |segment|
          return nil unless node.is_a?(Hash)

          node = node[segment]
        end
        node.is_a?(String) ? node : nil
      end

      # Deep merge where values from the more prioritary (left) backend win,
      # matching Chain#_deep_merge.
      def leftmost_merge(left, right)
        return right if left.nil?

        left.merge(right) do |_key, l, r|
          l.is_a?(Hash) && r.is_a?(Hash) ? leftmost_merge(l, r) : l
        end
      end

      def type_name(value)
        case value
        when Hash then :Hash
        when Array then :Array
        when String then :String
        when Symbol then :Symbol
        when Proc then :Proc
        when Integer then :Integer
        when Float then :Float
        when NilClass then :NilClass
        when TrueClass, FalseClass then :Boolean
        else value.class.name.to_sym
        end
      end

      # Splits a key like I18n.normalize_key (without touching the global
      # normalized-key cache).
      def split_key(key)
        key.to_s.split(@separator).reject(&:empty?).map do |part|
          case part
          when /\A[-+]?([1-9]\d*|0)\z/ then part.to_i
          when 'true' then true
          when 'false' then false
          else part.to_sym
          end
        end
      end

      # Loads translation files/directories into plain hashes using a throwaway
      # parser object -- no global I18n state is touched.
      class Loader
        TRANSLATION_EXTENSIONS = %w[rb yml yaml json].freeze

        # @return [[data, sources]] merged locale data plus a parallel tree
        #   recording the source file of every concrete value.
        def load(paths)
          data = {}
          sources = {}

          expand(paths).each do |file|
            parse(file).each do |locale, locale_data|
              locale = locale.to_sym
              deep_merge_data!(data, locale => locale_data || {})
              stamp_sources!(sources[locale] ||= {}, locale_data || {}, file)
            end
          end

          [data, sources]
        end

        private

        def expand(paths)
          files = Array(paths).flat_map do |path|
            if File.directory?(path)
              Dir.glob(File.join(path, '**', '*')).select { |f| File.file?(f) }
            elsif File.file?(path)
              [path]
            else
              raise ArgumentError, "translation path not found: #{path}"
            end
          end
          files.sort.select do |f|
            TRANSLATION_EXTENSIONS.include?(File.extname(f).delete_prefix('.').downcase)
          end
        end

        def parse(file)
          type = File.extname(file).delete_prefix('.').downcase
          type = 'yml' if type == 'yaml'

          reader = Class.new do
            include I18n::Backend::Base
            public :load_yml, :load_rb, :load_json
          end.new

          raw, already_symbolized = reader.send("load_#{type}", file)
          unless raw.is_a?(Hash)
            raise I18n::InvalidLocaleData.new(file, 'top level must be a Hash')
          end

          # load_yml/load_json freeze the data (Psych/JSON +freeze: true); copy
          # it into mutable structures so multiple files can be deep-merged and
          # so the checker never holds/modifies the parser's frozen objects.
          symbolized = already_symbolized ? raw : I18n::Utils.deep_symbolize_keys(raw)
          deep_dup(symbolized)
        rescue I18n::InvalidLocaleData
          raise
        rescue StandardError => e
          raise I18n::InvalidLocaleData.new(file, e.inspect)
        end

        def deep_merge_data!(hash, other)
          hash.merge!(other) do |_key, this_val, other_val|
            if this_val.is_a?(Hash) && other_val.is_a?(Hash)
              deep_merge_data!(this_val, other_val)
            else
              other_val
            end
          end
        end

        # Recursively copies Hash/Array structures (frozen or not) into mutable
        # ones. Scalar leaves are immutable and safe to share.
        def deep_dup(value)
          case value
          when Hash
            value.each_with_object({}) { |(k, v), out| out[k] = deep_dup(v) }
          when Array
            value.map { |element| deep_dup(element) }
          else
            value
          end
        end

        def stamp_sources!(source_node, value, file)
          return source_node unless value.is_a?(Hash)

          value.each do |key, child|
            if child.is_a?(Hash)
              stamp_sources!(source_node[key] ||= {}, child, file)
            else
              source_node[key] = file
            end
          end
          source_node
        end
      end
    end
  end
end
