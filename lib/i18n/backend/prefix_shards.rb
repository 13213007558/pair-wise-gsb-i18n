# frozen_string_literal: true

require 'monitor'
require 'i18n/backend/base'

module I18n
  module Backend
    # A backend that lazy loads translations in shards, keyed by locale and
    # key prefix. Instead of loading a whole locale (or the whole load path)
    # up front, an explicit manifest maps a locale + key prefix to a loader.
    # A lookup only loads the shard(s) covering the requested key:
    #
    #   backend = I18n::Backend::PrefixShards.new
    #   backend.register(:en, "billing")          { YAML.load_file("billing.en.yml") }
    #   backend.register(:en, "billing.invoices") { YAML.load_file("billing_invoices.en.yml") }
    #   backend.register(:en, "catalog")          { YAML.load_file("catalog.en.yml") }
    #
    #   I18n.t(:"billing.title")          # only loads the "billing" shard
    #   I18n.t(:"billing.invoices.title") # longest prefix wins: only "billing.invoices"
    #   I18n.t(:"billing")                # parent lookup: merges "billing" and
    #                                     # "billing.invoices" (and any deeper shards)
    #
    # Loader semantics:
    #
    # * A loader is any callable (or block) returning a Hash with the
    #   translations *below* its prefix. Keys are deep-symbolized.
    # * Longest prefix match wins: a key is looked up in the shard with the
    #   longest registered prefix that is a prefix of the key.
    # * When a lookup resolves to a subtree (parent node), all registered
    #   shards nested below the queried path are loaded and deep-merged into
    #   the result (deeper shards win on conflicts).
    # * Keys not covered by any registered prefix never trigger a load; they
    #   are only resolved against translations stored eagerly via
    #   #store_translations (if any).
    #
    # Aliases (Symbol values), pluralization and locale fallbacks keep working
    # as usual, since resolution goes through the regular Base backend flow.
    #
    # Concurrency: concurrent first lookups of the same shard share a single
    # load. If a loader raises, the shard is left in a failed (unloaded) state
    # and the exception propagates - no half-loaded data is exposed and the
    # next lookup retries the load. #reload_shard! resets a single shard
    # without touching the others; #reload! resets all of them.
    class PrefixShards
      include Base

      # A single shard of translations. Loads at most once per reset, shares
      # one load between concurrent callers and only exposes fully loaded data.
      class Shard
        def initialize(loader)
          @loader  = loader
          @monitor = Monitor.new
          @loaded  = @monitor.new_cond
          @state   = :pending # :pending, :loading, :loaded or :failed
          @data    = nil
        end

        def load
          @monitor.synchronize do
            loop do
              case @state
              when :loaded
                return @data
              when :loading
                @loaded.wait
              else # :pending or :failed (retry after a previous failure)
                return load_locked
              end
            end
          end
        end

        def reset
          @monitor.synchronize do
            @state = :pending
            @data  = nil
          end
          nil
        end

        def loaded?
          @monitor.synchronize { @state == :loaded }
        end

        private

        # Called with the monitor held. Other threads wait on the condition
        # variable until the load either completes or fails.
        def load_locked
          @state = :loading
          begin
            data   = @loader.call
            @data  = data
            @state = :loaded
            data
          rescue Exception
            @data  = nil
            @state = :failed
            raise
          ensure
            @loaded.broadcast
          end
        end
      end

      def initialize
        @manifest       = {} # locale (Symbol) => { prefix segments (Array<String>) => Shard }
        @manifest_mutex = Mutex.new
        @stored         = {} # locale (Symbol) => eagerly stored translations
        @stored_mutex   = Mutex.new
      end

      # Registers a loader for the given locale and key prefix. The loader is
      # called at most once per lookup miss and must return a Hash with the
      # translations below the prefix. Re-registering the same locale + prefix
      # replaces the previous shard and discards its loaded data.
      def register(locale, prefix, loader = nil, &block)
        loader ||= block
        raise ArgumentError, "a loader callable or block is required" unless loader.respond_to?(:call)

        locale   = locale.to_sym
        segments = normalize_prefix(prefix)
        shard    = Shard.new(lambda do
          data = loader.call
          unless data.is_a?(Hash)
            raise InvalidLocaleData.new("#{locale}.#{segments.join('.')}", "shard loaders must return a Hash, but returned #{data.class}")
          end
          Utils.deep_symbolize_keys(data)
        end)

        @manifest_mutex.synchronize do
          (@manifest[locale] ||= {})[segments] = shard
        end
        self
      end

      # Returns true if a shard is registered for the exact locale + prefix.
      def registered?(locale, prefix)
        @manifest_mutex.synchronize do
          shards = @manifest[locale.to_sym]
          !shards.nil? && shards.key?(normalize_prefix(prefix))
        end
      end

      # Stores translations eagerly, outside of any shard. These act as a
      # fallback layer for keys not covered by the manifest and never trigger
      # a shard load.
      def store_translations(locale, data, options = EMPTY_HASH)
        data = Utils.deep_symbolize_keys(data) unless options.fetch(:skip_symbolize_keys, false)
        @stored_mutex.synchronize do
          @stored[locale.to_sym] = Utils.deep_merge(@stored[locale.to_sym] || {}, data)
        end
        data
      end

      def available_locales
        (@manifest_mutex.synchronize { @manifest.keys } |
         @stored_mutex.synchronize { @stored.keys }).uniq
      end

      # Lists the currently loaded shards as "locale.prefix" strings.
      def loaded_shards
        manifest_entries.each_with_object([]) do |(locale, segments, shard), loaded|
          loaded << ([locale] + segments).join(".") if shard.loaded?
        end
      end

      def initialized?
        true
      end

      # Resets every shard so the next lookup reloads it. Eagerly stored
      # translations are cleared as well. The manifest itself is kept.
      def reload!
        manifest_entries.each { |_locale, _segments, shard| shard.reset }
        @stored_mutex.synchronize { @stored = {} }
        super
      end

      # Resets a single shard so the next lookup reloads it, leaving all
      # other shards (loaded or not) untouched. Returns false if no shard is
      # registered for the exact locale + prefix.
      def reload_shard!(locale, prefix)
        shard = shard_for(locale, prefix)
        return false unless shard

        shard.reset
        true
      end

      # Loads all registered shards.
      def eager_load!
        manifest_entries.each { |_locale, _segments, shard| shard.load }
        super
      end

      protected

      def lookup(locale, key, scope = [], options = EMPTY_HASH)
        keys  = I18n.normalize_keys(locale, key, scope, options[:separator])
        locale = keys.shift.to_sym
        path  = keys.map(&:to_s)

        covering, descendants = covering_shard(locale, path)

        result = nil
        if covering
          segments, shard = covering
          result = lookup_in(shard.load, path[segments.length..], locale, options)
        end

        # Parent node lookup: merge the shards registered below the path.
        # Leaf results (Strings etc.) shadow deeper shards, so those are not
        # even loaded in that case.
        if (result.nil? || result.is_a?(Hash)) && !descendants.empty?
          merged = result.is_a?(Hash) ? result : {}
          descendants.each do |segments, shard|
            merged = merge_trees(merged, wrap(segments[path.length..], shard.load))
          end
          result = merged unless merged.empty? && result.nil?
        end

        result = lookup_in(stored_for(locale), path, locale, options) if result.nil?
        result
      end

      private

      def normalize_prefix(prefix)
        segments = prefix.is_a?(Array) ? prefix : prefix.to_s.split(".")
        segments.map(&:to_s).freeze
      end

      def manifest_entries
        @manifest_mutex.synchronize do
          @manifest.flat_map do |locale, shards|
            shards.map { |segments, shard| [locale, segments, shard] }
          end
        end
      end

      def shard_for(locale, prefix)
        segments = normalize_prefix(prefix)
        @manifest_mutex.synchronize do
          shards = @manifest[locale.to_sym]
          shards && shards[segments]
        end
      end

      # Returns [covering, descendants] for the given path:
      # * covering    - the [segments, shard] pair with the longest registered
      #                 prefix that is a prefix of the path (or nil)
      # * descendants - all [segments, shard] pairs registered strictly below
      #                 the path, sorted shallowest first
      def covering_shard(locale, path)
        covering    = nil
        descendants = []

        @manifest_mutex.synchronize do
          (@manifest[locale] || {}).each do |segments, shard|
            if prefix_of?(segments, path)
              covering = [segments, shard] if covering.nil? || segments.length > covering[0].length
            elsif segments.length > path.length && prefix_of?(path, segments)
              descendants << [segments, shard]
            end
          end
        end

        descendants.sort_by! { |segments, _shard| segments.length }
        [covering, descendants]
      end

      def prefix_of?(prefix, path)
        prefix.length <= path.length && path[0, prefix.length] == prefix
      end

      def lookup_in(data, keys, locale, options)
        keys.inject(data) do |result, key|
          return nil unless result.is_a?(Hash)
          key = key.to_sym
          return nil unless result.has_key?(key)
          result = result[key]
          if result.is_a?(Symbol)
            result = resolve_entry(locale, key, result, Utils.except(options.merge(:scope => nil), :count))
          end
          result
        end
      end

      # Non-mutating deep merge; values from +other+ win on conflicts.
      def merge_trees(hash, other)
        hash.merge(other) do |_key, this_val, other_val|
          this_val.is_a?(Hash) && other_val.is_a?(Hash) ? merge_trees(this_val, other_val) : other_val
        end
      end

      # Wraps +data+ in nested hashes along the given path segments.
      def wrap(segments, data)
        segments.reverse.inject(data) { |acc, segment| { segment.to_sym => acc } }
      end

      def stored_for(locale)
        @stored_mutex.synchronize { @stored[locale] } || EMPTY_HASH
      end
    end
  end
end
