# frozen_string_literal: true

require 'i18n/backend/simple'

module I18n
  module Backend
    # A backend that lazy loads translations in shards, keyed by locale and
    # key prefix.
    #
    # Translation files are often split into many chunks per locale (e.g.
    # +billing+, +catalog+, +admin+), yet the Simple backend loads the whole
    # locale for a single lookup. This backend instead loads translations on
    # demand from an explicit manifest that maps a locale and a key prefix to
    # a loader (any object responding to +call+) returning the translations
    # below that prefix as a Hash:
    #
    #   backend = I18n::Backend::Sharded.new(
    #     en: {
    #       'billing' => -> { { 'invoices' => { 'title' => 'Invoices' } } },
    #       'catalog' => -> { { 'title' => 'Catalog' } }
    #     }
    #   )
    #   backend.register(:en, 'admin') { { 'title' => 'Admin' } }
    #
    #   I18n.backend = backend
    #   I18n.t('billing.invoices.title', locale: :en) # loads only the billing shard
    #
    # Lookup rules:
    #
    # * When several registered prefixes cover a key, the longest prefix
    #   wins: with shards for both "billing" and "billing.invoices", the key
    #   "billing.invoices.title" is owned (and only loaded) by the
    #   "billing.invoices" shard.
    # * Looking up a parent key (e.g. "billing") loads and merges every
    #   shard registered at or below that key.
    # * Keys not covered by the manifest at all do not trigger any load.
    #
    # Loaded shards are stored in the same in-memory tree the Simple backend
    # uses, so aliases (Symbol links), pluralization and locale fallbacks
    # (via I18n::Backend::Fallbacks) keep working.
    #
    # Concurrent first lookups of the same shard share a single load: the
    # loader is called exactly once and the other callers wait for its
    # result. Loads of different shards never block each other. If a loader
    # raises, nothing is stored and the next lookup retries the load, so a
    # failed load never exposes half-loaded results. A single shard can be
    # reloaded with #reload_shard without affecting any other shard.
    class Sharded < Simple
      # Accepts an optional manifest Hash of the form
      # { locale => { prefix => loader } } to pre-register shards.
      def initialize(manifest = nil)
        @manifest = {}
        @shard_states = {}
        @shard_lock = Mutex.new
        (manifest || {}).each do |locale, entries|
          entries.each { |prefix, loader| register(locale, prefix, loader) }
        end
      end

      # Registers a loader for the given locale and key prefix. The prefix
      # may be a String or Symbol using dots (e.g. "billing.invoices") or an
      # Array of key parts. The loader must respond to +call+ and return a
      # Hash with the translations below the prefix (string or symbol keys).
      def register(locale, prefix, loader = nil, &block)
        loader ||= block
        unless loader.respond_to?(:call)
          raise ArgumentError, 'shard loader must respond to #call'
        end
        entries = (@manifest[locale.to_sym] ||= {})
        parts = normalize_prefix(prefix)
        if entries.key?(parts)
          raise ArgumentError, "a shard is already registered for #{locale.inspect} / #{prefix.inspect}"
        end
        entries[parts] = loader
        self
      end

      # The Sharded backend never bulk-initializes: shards are loaded on
      # demand by #lookup.
      def initialized?
        true
      end

      def available_locales
        @manifest.keys | super
      end

      # Eagerly loads every shard registered in the manifest.
      def eager_load!
        @manifest.each do |locale, entries|
          entries.each_key { |parts| load_shard(locale, parts) }
        end
        @eager_loaded = true
      end

      # Clears all loaded shards and translations.
      def reload!
        @shard_lock.synchronize { @shard_states.clear }
        @translations = nil
        eager_load! if eager_loaded?
        self
      end

      # Clears a single shard so the next lookup loads it again. The
      # translations and load state of every other shard are left untouched.
      def reload_shard(locale, prefix)
        parts = normalize_prefix(prefix)
        @shard_lock.synchronize do
          @shard_states.delete([locale.to_sym, parts])
          remove_shard_data(locale.to_sym, parts)
        end
        self
      end

      protected

      def lookup(locale, key, scope = [], options = EMPTY_HASH)
        keys = I18n.normalize_keys(locale, key, scope, options[:separator])
        ensure_shards_loaded(keys.first.to_sym, keys[1..-1].map { |k| k.to_s.to_sym })
        super
      end

      private

      def normalize_prefix(prefix)
        parts = prefix.is_a?(Array) ? prefix : prefix.to_s.split('.')
        parts.map { |part| part.to_s.to_sym }.freeze
      end

      # Loads the shard that owns the given key path (longest matching
      # prefix) plus, for parent key lookups, every shard registered below
      # the path. Does nothing when the manifest does not cover the path.
      def ensure_shards_loaded(locale, path)
        entries = @manifest[locale]
        return unless entries

        longest = nil
        descendants = []
        entries.each_key do |parts|
          if prefix_of?(parts, path)
            longest = parts if longest.nil? || parts.length > longest.length
          elsif parts.length > path.length && prefix_of?(path, parts)
            descendants << parts
          end
        end

        load_shard(locale, longest) if longest
        descendants.each { |parts| load_shard(locale, parts) }
      end

      def prefix_of?(prefix, path)
        prefix.length <= path.length && path.first(prefix.length) == prefix
      end

      # Loads a single shard. Concurrent callers share one in-flight load:
      # the first caller runs the loader while the others wait for it. On
      # failure the shard state is reset (so the next lookup retries) and
      # the error is re-raised; data is only merged into the translations
      # tree after the loader has returned successfully.
      def load_shard(locale, parts)
        loader = @manifest.fetch(locale, EMPTY_HASH)[parts]
        return unless loader
        key = [locale, parts]

        loop do
          owner = false
          cv = nil

          @shard_lock.synchronize do
            case (state = @shard_states[key])
            when :loaded
              return
            when ConditionVariable
              # Another thread is loading this shard; wait for it to finish.
              state.wait(@shard_lock) while @shard_states[key].equal?(state)
            else
              @shard_states[key] = cv = ConditionVariable.new
              owner = true
            end
          end

          next unless owner

          begin
            data = loader.call
            unless data.is_a?(Hash)
              raise InvalidLocaleData.new("#{locale}.#{parts.join('.')}", 'shard loader must return a Hash')
            end
            @shard_lock.synchronize do
              # The state may have been cleared by reload!/reload_shard while
              # loading; in that case discard the result instead of exposing
              # stale data.
              if @shard_states[key].equal?(cv)
                store_shard_data(locale, parts, data)
                @shard_states[key] = :loaded
              end
              cv.broadcast
            end
            return
          rescue Exception
            @shard_lock.synchronize do
              @shard_states.delete(key) if @shard_states[key].equal?(cv)
              cv.broadcast
            end
            raise
          end
        end
      end

      # Merges the shard data into the translations tree below the shard's
      # prefix. Called with @shard_lock held, after the loader returned
      # successfully.
      def store_shard_data(locale, parts, data)
        node = translations[locale]
        parts.each do |part|
          child = node[part]
          unless child.is_a?(Hash)
            child = Concurrent::Hash.new
            node[part] = child
          end
          node = child
        end
        Utils.deep_merge!(node, Utils.deep_symbolize_keys(data))
      end

      # Removes the translations tree below the shard's prefix without
      # touching any other shard's data. Called with @shard_lock held.
      def remove_shard_data(locale, parts)
        return unless @translations && @translations[locale]
        if parts.empty?
          @translations.delete(locale)
          return
        end
        node = @translations[locale]
        parts[0..-2].each do |part|
          node = node[part]
          return unless node.is_a?(Hash)
        end
        node.delete(parts[-1])
      end
    end
  end
end
