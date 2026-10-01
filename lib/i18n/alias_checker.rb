# frozen_string_literal: true

# I18n::AliasChecker
#
# A read-only, static checker for Symbol aliases ("links") in translation
# files. Given an ordered backend chain (directories of translation files)
# and locale fallback rules it resolves every alias exactly the way a real
# I18n lookup would:
#
#   * backends are queried in chain order (the first backend has priority);
#   * locale fallbacks are tried in the same order I18n::Backend::Fallbacks
#     uses (self, parents, explicit mappings, then default locales);
#   * a Symbol hit while digging a key restarts the *whole* lookup with the
#     fallback chain of the originally requested locale and the complete
#     backend chain - so an alias in backend 1 can point into backend 2
#     and back again;
#   * Proc (and other callable) values are dynamic, never statically
#     decidable, and are reported as such - they are NEVER invoked.
#
# It reports circular aliases, dangling aliases and the final target type
# of every resolvable alias, with the complete resolution chain (backend,
# locale and file of every hop).
#
# The checker never writes to, nor mutates, any I18n translation cache:
# files are parsed into detached plain hashes and the analysis is purely
# functional. It neither needs Rails nor instantiates I18n backends.
module I18n
  module AliasChecker
    class LoadError < StandardError; end

    # A single translation file loaded into memory.
    FileEntry = Struct.new(:path, :locale, :data, keyword_init: true)

    # A backend in the chain. Chain order == query priority order.
    Backend = Struct.new(:name, :files, keyword_init: true)

    # One hop in an alias resolution chain.
    #   key     - absolute key of this alias entry
    #   value   - the Symbol it points at (nil for a terminal node)
    #   backend - index of the backend the entry was found in
    #   locale  - locale entry that actually contained it (may differ from
    #             the requested locale because of locale fallbacks)
    #   file    - file the entry was defined in
    Hop = Struct.new(:key, :value, :backend, :locale, :file, keyword_init: true)

    # Outcome of resolving one alias.
    #   status - :ok | :dynamic | :dangling | :cycle
    #   type   - final target type for :ok (e.g. "String", "Hash")
    #   hops   - ordered list of Hop (alias hops only, then terminal)
    #   cycle  - ordered array of absolute keys forming the cycle
    Result = Struct.new(:status, :type, :hops, :cycle, :request_locale,
                        :request_key, keyword_init: true) do
      def terminal
        hops.last
      end
    end

    extend self

    # ------------------------------------------------------------------
    # Loading (read only; produces detached plain hashes)
    # ------------------------------------------------------------------

    # Builds the ordered backend chain from directory paths.
    # Returns [Array<Backend>, Array<String>] (the second holds load errors).
    def load_backends(directories)
      errors = []
      backends = directories.each_with_index.map do |dir, index|
        paths =
          Dir.glob(File.join(dir.to_s, '**', '*')).grep(
            /\.(?:rb|ya?ml|json)\z/
          ).sort
        files = paths.map do |path|
          load_file(path)
        rescue LoadError => e
          errors << e.message
          nil
        end.compact
        Backend.new(name: File.basename(dir.to_s), files: files)
      end
      [backends, errors]
    end

    def load_file(path)
      data =
        case File.extname(path).downcase
        when '.rb'          then parse_rb(path)
        when '.yml', '.yaml' then parse_yml(path)
        when '.json'        then parse_json(path)
        else raise LoadError, "unsupported file type: #{path}"
        end

      raise LoadError, "#{path}: expected top-level Hash with locale keys" unless data.is_a?(Hash)

      data = deep_symbolize_keys(data)
      entries = data.map do |locale, d|
        FileEntry.new(path: path, locale: locale.to_sym, data: d.is_a?(Hash) ? d : {})
      end
      entries.first # one file == one locale, like I18n translation files
    end

    def parse_rb(path)
      data = eval(IO.read(path), TOPLEVEL_BINDING, path) # rubocop:disable Security/Eval
      raise LoadError, "#{path}: expected a Hash but got #{data.class}" unless data.is_a?(Hash)
      deep_symbolize_keys(data)
    rescue ScriptError, StandardError => e
      raise LoadError, "#{path}: #{e.class}: #{e.message}"
    end

    def parse_yml(path)
      require 'yaml'
      data =
        if YAML.respond_to?(:unsafe_load_file) # Psych 4
          YAML.unsafe_load_file(path, symbolize_names: true)
        else
          d = YAML.load_file(path)
          d.is_a?(Hash) ? deep_symbolize_keys(d) : d
        end
      data || {}
    rescue TypeError, ScriptError, StandardError => e
      raise LoadError, "#{path}: #{e.class}: #{e.message}"
    end

    def parse_json(path)
      require 'json'
      data =
        if ::JSON.respond_to?(:load_file)
          ::JSON.load_file(path, symbolize_names: true)
        else
          ::JSON.parse(File.read(path))
        end
      data || {}
    rescue TypeError, StandardError => e
      raise LoadError, "#{path}: #{e.class}: #{e.message}"
    end

    # ------------------------------------------------------------------
    # Fallback chain (mirrors I18n::Locale::Fallbacks)
    # ------------------------------------------------------------------

    class Fallbacks
      def initialize(defaults: [], mappings: {})
        @map = {}
        # Defaults are pre-computed BEFORE mappings exist, exactly like
        # I18n::Locale::Fallbacks (whose defaults= runs in its
        # constructor before .map is called), so mappings never apply to
        # default locales.
        @defaults = Array(defaults).flat_map { |d| compute(d, false) }.uniq
        (mappings || {}).each do |from, tos|
          @map[from.to_sym] = Array(tos).map { |t| t.to_sym }
        end
      end

      def [](locale)
        raise ArgumentError, 'locale must not be nil' if locale.nil?
        @cache ||= {}
        @cache[locale.to_sym] ||= compute(locale.to_sym)
      end

      private

      def compute(tag, include_defaults = true, exclude = [])
        result = []
        # all parents first (self_and_parents), in order
        tags = parents(tag) - exclude
        result.concat(tags)
        # explicit mappings declared on any reached parent, applied after
        # the parents themselves (e.g. x-y => m-n yields x-y, x, m-n, m)
        tags.each do |p|
          Array(@map[p]).each do |mapped|
            result.concat(compute(mapped, false, exclude + result))
          end
        end
        result.push(*@defaults) if include_defaults
        result.uniq
      end

      # :"en-US-texas" => [:"en-US-texas", :"en-US", :en]
      def parents(tag)
        parts = tag.to_s.split('-')
        Array.new(parts.length) { |i| parts[0, parts.length - i].join('-').to_sym }
      end
    end

    # ------------------------------------------------------------------
    # Resolution engine
    # ------------------------------------------------------------------

    class Engine
      MISSING = :__i18n_alias_checker_missing__

      def initialize(backends, fallbacks)
        @backends = backends
        @fallbacks = fallbacks
        @tree_cache = {}
        # Per-top-level-resolution DFS state (allocated fresh by #resolve):
        @color = nil  # [locale, segs] => :gray on the active path
        @path = nil   # active stack of [locale, segs]
      end

      def locales
        @locales ||= @backends.flat_map { |b| b.files.map(&:locale) }.uniq
      end

      # Every alias entry across all backend files:
      # [[backend_index, locale, segments, symbol, file]]
      def aliases
        @aliases ||=
          @backends.each_with_index.flat_map do |backend, bi|
            backend.files.flat_map do |file|
              collect_aliases(bi, file.locale, [], file.data, file.path)
            end
          end
      end

      # Resolve is public (used by the analyzer and tests).
      def resolve(locale, key)
        segs = segments(key)
        @color = {}
        @path = []
        @hop_stack = [nil] # nil hop aligned with the root path frame
        outcome = walk(locale, segs)
        outcome.merge(request_locale: locale, request_segments: segs)
      end

      # Whether the alias ENTRY at +segs+ is itself reachable from
      # +locale+ (its containing key exists somewhere in the chain under
      # that locale's fallbacks). Independent of whether the alias target
      # resolves. Used to decide which aliases to report per locale.
      def entry_visible?(locale, segs)
        @fallbacks[locale].any? do |fb|
          @backends.each_with_index.any? do |_backend, bi|
            tree_for(bi, fb, segs)
          end
        end
      end

      def tree_for(bi, locale, segs)
        tree, _src = raw_tree(bi, locale)
        return false if tree.nil?
        node = tree
        segs.all? do |seg|
          node.is_a?(Hash) && node.key?(seg) && (node = node[seg]; true)
        end
      end

      private

      def collect_aliases(bi, locale, prefix, data, file)
        return [] unless data.is_a?(Hash)
        data.flat_map do |k, v|
          path = prefix + [k]
          case v
          when Symbol then [[bi, locale, path, v, file]]
          when Hash   then collect_aliases(bi, locale, path, v, file)
          else []
          end
        end
      end

      # Gray DFS over [requested_locale, segments]. State is reset per
      # top-level #resolve.
      def walk(locale, segs)
        key = [locale, segs]
        if @color[key] == :gray
          idx = @path.rindex(key)
          nodes = idx ? @path[idx..] : [key]
          labels = nodes.map { |(_l, seg)| key_to_sym(seg) }
          labels << labels.first
          # @path frames and @hop_stack entries line up 1:1; the hop for
          # frame i is the link leading INTO it (nil on the root frame).
          # follow_link pushes the inbound hop before descending, so the
          # closing hop is already present when a gray node is revisited.
          cycle_hops = (@hop_stack[idx..] || []).compact
          return { status: :cycle, cycle: labels, hops: cycle_hops }
        end

        @color[key] = :gray
        @path.push(key)
        outcome = chain_translate(locale, segs, locale)
        @path.pop
        @color.delete(key)
        outcome
      end

      # Chain#translate: backends are tried in order; each backend runs
      # its own locale fallback search internally (backend priority beats
      # fallback locale). +original+ is the requested locale that any
      # encountered link must resolve against (Fallbacks#resolve_entry
      # passes fallback_original_locale, NOT the current fallback locale).
      def chain_translate(fb_root, segs, original)
        @backends.each_with_index do |_b, bi|
          outcome = backend_with_fallbacks(bi, fb_root, segs, original)
          next if outcome == MISSING

          unless outcome[:status] == :ok && outcome[:type] == 'Hash'
            # scalar / dynamic / cycle from this backend wins outright
            return outcome
          end

          # Namespace (Hash) hit: Chain keeps merging later backends so
          # missing subkeys can be completed - BUT a later backend that
          # supplies a NON-hash value at this key replaces the namespace
          # entirely (e.g. its own better-locale scalar for this key).
          merged = outcome
          @backends.each_with_index do |_later, lj|
            next if lj <= bi
            extra = backend_with_fallbacks(lj, fb_root, segs, original)
            next if extra == MISSING
            return extra unless extra[:status] == :ok && extra[:type] == 'Hash'
            merged = {
              status: :ok, type: 'Hash',
              node: deep_merge_priority(merged[:node], extra[:node]),
              hops: merged[:hops] + extra[:hops],
              terminal: merged[:terminal]
            }
          end
          return merged
        end
        dangling
      end

      # One backend's Fallbacks#translate: try this backend at each
      # fallback locale in order; first non-nil hit wins.
      def backend_with_fallbacks(bi, root_locale, segs, original)
        @fallbacks[root_locale].each do |fb|
          outcome = lookup_in(bi, fb, segs, original, [])
          return outcome unless outcome == MISSING
        end
        MISSING
      end

      # Simple#lookup for one backend + one concrete fallback locale.
      # A Symbol restarts FULL resolution rooted at +original+ (the
      # requested locale), over the complete backend chain.
      def lookup_in(bi, fb, segs, original, hops)
        tree, src = raw_tree(bi, fb)
        return MISSING if tree.nil?

        node = tree
        segs.each_with_index do |seg, idx|
          unless node.is_a?(Hash) && node.key?(seg)
            return MISSING
          end
          value = node[seg]
          used_path = segs[0..idx]
          rest = segs[(idx + 1)..]

          case value
          when Symbol
            hop = Hop.new(
              key: join(used_path), value: value, backend: bi,
              locale: fb, file: src.dig_path(used_path)
            )
            return follow(value, rest, original, hops + [hop])
          when Proc
            return { status: :dynamic, type: 'Proc', hops: hops }
          when nil
            return MISSING
          else
            node = value
          end
        end

        classify(node, bi, fb, src, segs, hops)
      end

      # Link target: full resolution with the ORIGINAL requested locale,
      # then apply any remaining dotted-key segments.
      def follow(symbol, rest, original, hops)
        @hop_stack.push(hops.last)
        outcome = walk(original, segments(symbol))
        @hop_stack.pop unless outcome[:status] == :cycle
        return outcome if outcome[:status] == :cycle
        return MISSING if outcome[:status] == :dangling
        outcome = outcome.merge(hops: hops + outcome[:hops].to_a)
        return outcome if outcome[:status] != :ok
        return outcome if rest.empty?
        apply_suffix(outcome, rest, original, hops)
      end

      def apply_suffix(outcome, rest, original, hops)
        node = outcome[:node]
        rest.each do |seg|
          unless node.is_a?(Hash) && node.key?(seg)
            return MISSING
          end
          value = node[seg]
          case value
          when Symbol then return follow(value, [], original, hops)
          when Proc   then return { status: :dynamic, type: 'Proc', hops: hops }
          when nil    then return MISSING
          else node = value
          end
        end
        case node
        when Proc then { status: :dynamic, type: 'Proc', hops: hops }
        else
          {
            status: :ok, type: node.class.name, hops: hops,
            terminal: Hop.new(key: nil, value: nil, backend: nil,
                              locale: original, file: nil)
          }
        end
      end

      def classify(node, bi, locale, src, segs, hops)
        case node
        when Proc then { status: :dynamic, type: 'Proc', hops: hops }
        when Hash
          {
            status: :ok, type: 'Hash', node: node, hops: hops,
            terminal: Hop.new(
              key: join(segs), value: nil, backend: bi, locale: locale,
              file: src&.dig_path(segs)
            )
          }
        else
          {
            status: :ok, type: node.class.name, hops: hops,
            terminal: Hop.new(
              key: join(segs), value: nil, backend: bi, locale: locale,
              file: src&.dig_path(segs)
            )
          }
        end
      end

      def dangling
        { status: :dangling, type: nil, hops: [] }
      end

      # ---------------- raw trees with leaf provenance ----------------

      SrcMap = Struct.new(:map) do
        def dig_path(segs)
          map[segs]
        end
      end

      def raw_tree(bi, locale)
        @tree_cache[[bi, locale]] ||=
          begin
            merged = nil
            src = {}
            @backends[bi].files.select { |f| f.locale == locale }.each do |file|
              merged = merged.nil? ? deep_dup(file.data) : deep_merge_priority(merged, file.data)
              record_src(file.data, [], file.path, src)
            end
            merged.nil? ? nil : [merged, SrcMap.new(src)]
          end
      end

      def record_src(data, path, file, src)
        return unless data.is_a?(Hash)
        data.each do |k, v|
          cur = path + [k]
          src[cur] = file # later file wins, consistent with data merge
          record_src(v, cur, file, src) if v.is_a?(Hash)
        end
      end

      # ---------------- helpers ----------------

      def segments(key)
        case key
        when Array then key
        when Symbol, String
          key.to_s.split('.').reject(&:empty?).map(&:to_sym)
        else [key]
        end
      end

      def join(segs)
        key_to_sym(segs)
      end

      def key_to_sym(segs)
        segs.map(&:to_s).join('.').to_sym
      end

      # Left side wins (earlier backend / earlier part of the chain),
      # matching Chain#_deep_merge.
      def deep_merge_priority(left, right)
        left.merge(right) do |_k, lv, rv|
          (lv.is_a?(Hash) && rv.is_a?(Hash)) ? deep_merge_priority(lv, rv) : lv
        end
      end

      def deep_dup(value)
        case value
        when Hash then value.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
        when Array then value.map { |v| deep_dup(v) }
        else value
        end
      end
    end

    def deep_symbolize_keys(hash)
      case hash
      when Hash
        hash.each_with_object({}) do |(k, v), out|
          out[k.respond_to?(:to_sym) ? k.to_sym : k] = deep_symbolize_keys(v)
        end
      when Array then hash.map { |v| deep_symbolize_keys(v) }
      else hash
      end
    end

    # ------------------------------------------------------------------
    # Analysis: resolve every alias visible from every requesting locale
    # and attach full, deduplicated hop provenance.
    # ------------------------------------------------------------------

    # One detected cycle: the canonical cycle keys (rotated to a
    # deterministic start), the requesting locale and every alias entry
    # that leads into the cycle (with its full hop chain).
    CycleGroup = Struct.new(:request_locale, :cycle, :entries, keyword_init: true)

    Report = Struct.new(:results, :load_errors, :cycles, keyword_init: true) do
      def danglings; results.select { |r| r.status == :dangling }; end
      def dynamics; results.select { |r| r.status == :dynamic }; end
      def oks;      results.select { |r| r.status == :ok };      end
    end

    def analyze(backends, errors, defaults: [], mappings: {})
      fallbacks = Fallbacks.new(defaults: defaults, mappings: mappings)
      engine = Engine.new(backends, fallbacks)
      results = []
      cycle_groups = {} # fingerprint => CycleGroup

      engine.locales.each do |requested_locale|
        engine.aliases.each do |bi, alias_locale, segs, symbol, file|
          # Report only aliases whose own entry is reachable from this
          # requesting locale (its containing key exists under that
          # locale's fallbacks). The alias target may still dangle.
          next unless engine.entry_visible?(requested_locale, segs)

          outcome = engine.resolve(requested_locale, segs)
          result = Result.new(
            status: outcome[:status],
            type: outcome[:type],
            hops: build_hops(outcome, bi, alias_locale, segs, symbol, file),
            cycle: outcome[:cycle],
            request_locale: requested_locale,
            request_key: segs.map(&:to_s).join('.').to_sym
          )

          if result.status == :cycle
            canonical = canonical_cycle(result.cycle)
            fingerprint = "#{requested_locale}:#{canonical.map(&:to_s).join('|')}"
            group = (cycle_groups[fingerprint] ||= CycleGroup.new(
              request_locale: requested_locale, cycle: canonical, entries: []
            ))
            group.entries << result
          else
            results << result
          end
        end
      end

      # de-duplicate non-cycle entries that are identical across
      # requesting locales (e.g. an en alias visible from both de and
      # de-DE resolving identically) - keep distinct chains though.
      results = results.uniq do |r|
        [r.status, r.type, r.request_locale, r.request_key,
         r.hops.map { |h| [h.key, h.value, h.backend, h.locale, h.file] }]
      end.sort_by { |r| [r.status.to_s, r.request_locale.to_s, r.request_key.to_s] }

      Report.new(results: results, load_errors: errors,
                 cycles: cycle_groups.values)
    end

    # Rotate the closed cycle key list ([a, b, ..., a]) so it starts at
    # its lexicographically smallest element, making the same cycle
    # reached from different entry points compare equal.
    def canonical_cycle(keys)
      return keys if keys.nil? || keys.empty?
      body = keys.first == keys.last ? keys[0...-1] : keys.dup
      return [body.first] if body.length <= 1
      min = body.min
      idx = body.index(min)
      rotated = body.rotate(idx)
      rotated + [rotated.first]
    end

    # The first hop is the alias entry as found on disk; subsequent hops
    # come from the resolver (which records each Symbol restart), and the
    # final hop is the concrete terminal with file/backend provenance.
    def self.build_hops(outcome, bi, alias_locale, segs, symbol, file)
      first = Hop.new(
        key: segs.map(&:to_s).join('.').to_sym, value: symbol,
        backend: bi, locale: alias_locale, file: file
      )
      hops = [first] + (outcome[:hops] || [])
      hops = hops.uniq { |h| [h.key, h.value, h.backend, h.locale] }
      terminal = outcome[:terminal]
      if terminal && hops.none? { |h| h.key == terminal.key && h.value.nil? && h.file == terminal.file }
        hops = hops + [terminal]
      end
      hops
    end
  end
end

# ----------------------------------------------------------------------
# Text / JSON rendering
# ----------------------------------------------------------------------

module I18n::AliasChecker
  extend self

  def format_report(report, backends, format: :text, show_ok: false)
    case format.to_sym
    when :json then format_json(report, backends, show_ok)
    else format_text(report, backends, show_ok)
    end
  end

  def format_text(report, backends, show_ok)
    out = +""
    backend_names = backends.map.with_index { |b, i| "##{i} #{b.name}" }
    out << "Backend chain (priority order): #{backend_names.join(' -> ')}\n\n"

    if report.load_errors.any?
      out << "FILE LOAD ERRORS (#{report.load_errors.size}):\n"
      report.load_errors.each { |e| out << "  ! #{e}\n" }
      out << "\n"
    end

    unless report.cycles.empty?
      out << "CIRCULAR ALIASES (#{report.cycles.size}):\n"
      report.cycles.each { |group| out << render_cycle(group) }
      out << "\n"
    end

    unless report.danglings.empty?
      out << "DANGLING ALIASES (#{report.danglings.size}):\n"
      report.danglings.each { |r| out << render_result(r) }
      out << "\n"
    end

    unless report.dynamics.empty?
      out << "DYNAMIC TARGETS - CANNOT BE STATICALLY RESOLVED (#{report.dynamics.size}):\n"
      report.dynamics.each { |r| out << render_result(r) }
      out << "\n"
    end

    if show_ok
      out << "RESOLVABLE ALIASES (#{report.oks.size}):\n"
      report.oks.each { |r| out << render_result(r) }
      out << "\n"
    end

    out << "Summary: #{report.cycles.size} cycle(s), #{report.danglings.size} dangling, ""#{report.dynamics.size} dynamic, #{report.oks.size} ok\n"
    if report.cycles.empty? && report.danglings.empty? && report.load_errors.empty?
      out << "No alias problems found.\n"
    end
    out
  end

  def render_cycle(group)
    line = +"  [CYCLE] locale=#{group.request_locale}\n"
    line << "    cycle: #{group.cycle.map(&:to_s).join(' -> ')}\n"
    line << "    entry points (#{group.entries.size}):\n"
    group.entries.each do |r|
      line << "      #{r.request_locale}.#{r.request_key}\n"
      line << render_chain(r, indent: '        ')
    end
    line
  end

  def render_result(r)
    label = { ok: 'OK', dynamic: 'DYNAMIC', dangling: 'DANGLING' }[r.status]
    line = +"  [#{label}] #{r.request_locale}.#{r.request_key}"
    line << " -> #{r.type}" if r.status == :ok
    line << "\n"
    line << render_chain(r)
  end

  def render_chain(r, indent: '      ')
    return +"" if r.hops.empty?
    lines = +"#{indent}chain:\n"
    r.hops.each do |hop|
      where = "backend ##{hop.backend}" unless hop.backend.nil?
      src = hop.locale
      target = hop.value ? " => :#{hop.value}" : " [terminal]"
      file = hop.file ? "  [#{hop.file}]" : ""
      lines << "#{indent}  #{hop.key} (#{[where, src].compact.join(', ')})#{target}#{file}\n"
    end
    lines
  end

  def format_json(report, backends, show_ok)
    require 'json'
    pick = show_ok ? report.results : report.results.reject { |r| r.status == :ok }
    data = {
      backends: backends.map(&:name),
      load_errors: report.load_errors,
      summary: {
        cycle: report.cycles.size,
        dangling: report.danglings.size,
        dynamic: report.dynamics.size,
        ok: report.oks.size
      },
      cycles: report.cycles.map do |g|
        {
          request_locale: g.request_locale.to_s,
          cycle: g.cycle.map(&:to_s),
          entries: g.entries.map { |r| result_json(r) }
        }
      end,
      results: pick.map { |r| result_json(r) }
    }
    ::JSON.pretty_generate(data) << "\n"
  end

  def result_json(r)
    {
      status: r.status.to_s,
      type: r.type,
      request_locale: r.request_locale.to_s,
      request_key: r.request_key.to_s,
      hops: r.hops.map do |h|
        {
          key: h.key&.to_s, value: h.value&.to_s,
          backend: h.backend, locale: h.locale&.to_s, file: h.file
        }
      end
    }
  end
end
