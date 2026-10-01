# frozen_string_literal: true

require 'minitest/autorun'
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'i18n/alias_checker'

class AliasCheckerTest < Minitest::Test
  AliasChecker = I18n::AliasChecker

  def checker(*dirs, defaults: [], mappings: {})
    backends, errors = AliasChecker.load_backends(dirs.map { |d| fixture(d) })
    assert_equal [], errors
    AliasChecker.analyze(backends, errors, defaults: defaults, mappings: mappings)
  end

  def fixture(name)
    File.join(File.dirname(__FILE__), 'test_data', 'alias_check', name)
  end

  def by_key(report, locale = :en)
    report.results.select { |r| r.request_locale == locale }
                 .to_h { |r| [r.request_key, r] }
  end

  # ------------------------------------------------------------------
  # basic resolution
  # ------------------------------------------------------------------

  def test_resolves_simple_string_alias_with_type_and_chain
    report = checker('healthy')
    r = by_key(report)[:simple]
    assert_equal :ok, r.status
    assert_equal 'String', r.type
    keys = r.hops.map(&:key)
    assert_equal [:'simple', :'target'], keys
    assert_equal :'target', r.hops.first.value
    assert_nil r.hops.last.value # terminal node
  end

  def test_reports_dotted_alias_and_integer_terminal_type
    report = checker('healthy')
    r = by_key(report)[:'nested.link']
    assert_equal :ok, r.status
    assert_equal 'Integer', r.type
    assert_equal [:'nested.link', :'deep.value'], r.hops.map(&:key)
  end

  def test_alias_to_namespace_resolves_to_hash
    report = checker('healthy')
    r = by_key(report)[:alias_to_ns]
    assert_equal :ok, r.status
    assert_equal 'Hash', r.type
  end

  # ------------------------------------------------------------------
  # dangling
  # ------------------------------------------------------------------

  def test_dangling_alias_is_reported
    Dir.mktmpdir do |dir|
      write(dir, 'en.yml', <<~YAML)
        en:
          orphan: :does.not.exist
      YAML
      backends, errors = AliasChecker.load_backends([dir])
      report = AliasChecker.analyze(backends, errors)
      assert_equal :dangling, report.results.first.status
      assert_equal [:'orphan'], report.results.first.hops.map(&:key)
    end
  end

  # ------------------------------------------------------------------
  # cycles inside one file
  # ------------------------------------------------------------------

  def test_detects_self_cycle
    report = build(en: { a: :a })
    assert_equal 1, report.cycles.size
    assert_equal [:a], report.cycles.first.cycle
  end

  def test_detects_two_node_cycle
    report = build(en: { a: :b, b: :a, ok: 'fine' })
    assert_equal 1, report.cycles.size
    group = report.cycles.first
    assert_equal [:a, :b, :a], group.cycle
    keys = group.entries.map(&:request_key).sort
    assert_equal [:a, :b], keys
  end

  def test_node_leading_into_cycle_is_grouped_as_entry_point
    report = build(en: { entry: :a, a: :b, b: :a })
    group = report.cycles.first
    assert_equal [:a, :b, :a], group.cycle
    assert_equal [:entry, :a, :b].sort, group.entries.map(&:request_key).sort
  end

  # ------------------------------------------------------------------
  # the headline feature: cycle only across two backends
  # ------------------------------------------------------------------

  def test_no_cycle_when_backends_checked_individually
    a = checker('cross_backend_cycle/app_backend')
    b = checker('cross_backend_cycle/gem_backend')
    assert_equal 0, a.cycles.size
    assert_equal 0, b.cycles.size
    assert(a.danglings.any? { |r| r.request_key == :'promo.banner' })
    assert(b.danglings.any? { |r| r.request_key == :'marketing.offer' })
  end

  def test_cycle_only_forms_after_chaining_two_backends
    report = checker('cross_backend_cycle/app_backend',
                     'cross_backend_cycle/gem_backend')
    assert_equal 1, report.cycles.size
    group = report.cycles.first
    assert_equal [:'marketing.offer', :'promo.banner', :'marketing.offer'],
                 group.cycle

    app_hop = group.entries.flat_map(&:hops).find { |h| h.backend == 0 }
    gem_hop = group.entries.flat_map(&:hops).find { |h| h.backend == 1 }
    assert_equal :'promo.banner', app_hop.key
    assert_equal :'marketing.offer', gem_hop.key
    assert app_hop.file.include?('app_backend')
    assert gem_hop.file.include?('gem_backend')

    # the unrelated dangling alias is still reported
    assert report.danglings.any? { |r| r.request_key == :'other.dangle' }
    # the healthy key that exists on its own produces no false positive
    assert report.results.none? { |r| r.request_key == :'other.fine' }
  end

  # ------------------------------------------------------------------
  # backend priority / shadowing
  # ------------------------------------------------------------------

  def test_first_backend_wins_for_scalar_alias
    report = build_two(
      { en: { a: :target, target: 'first' } },
      { en: { target: 'second' } }
    )
    r = by_key(report)[:a]
    assert_equal :ok, r.status
    assert_equal 'String', r.type
    term = r.hops.last
    assert_equal 0, term.backend
  end

  # ------------------------------------------------------------------
  # locale fallbacks
  # ------------------------------------------------------------------

  def test_locale_fallbacks_follow_parents_and_defaults
    report = checker('locales_a', 'locales_b', defaults: [:en])

    # de-DE.gruss -> de.hello -> de.willkommen (parent locale fallback)
    de_de = report.results.find { |r| r.request_locale == :'de-DE' &&
                                     r.request_key == :gruss }
    assert_equal :ok, de_de.status
    locales = de_de.hops.map(&:locale)
    assert_includes locales, :'de-DE'
    assert_includes locales, :de

    # de.jumps_to_en -> en.welcome (default locale fallback)
    jump = report.results.find { |r| r.request_locale == :de &&
                                    r.request_key == :jumps_to_en }
    assert_equal :ok, jump.status
    en_hop = jump.hops.find { |h| h.locale == :en }
    refute_nil en_hop
  end

  def test_cross_locale_fallback_can_form_cycle_visible_only_from_one_locale
    Dir.mktmpdir do |root|
      a_dir = File.join(root, 'a'); b_dir = File.join(root, 'b')
      FileUtils.mkdir_p([a_dir, b_dir])
      write(a_dir, 'en.yml', 'en:' + "\n  alpha: :beta\n")
      write(b_dir, 'de.yml', 'de:' + "\n  beta: :alpha\n")
      backends, errors = AliasChecker.load_backends([a_dir, b_dir])
      report = AliasChecker.analyze(backends, errors, defaults: [:en])

      group = report.cycles.find { |g| g.request_locale == :de }
      refute_nil group, 'de must see the fallback cycle'
      assert_equal [:alpha, :beta, :alpha], group.cycle

      # from en, beta only exists in de, so it merely dangles
      en_alpha = report.results.find { |r| r.request_locale == :en &&
                                         r.request_key == :alpha }
      assert_equal :dangling, en_alpha.status
    end
  end

  def test_without_default_fallback_the_same_alias_dangles
    Dir.mktmpdir do |root|
      a_dir = File.join(root, 'a'); b_dir = File.join(root, 'b')
      FileUtils.mkdir_p([a_dir, b_dir])
      write(a_dir, 'en.yml', 'en:' + "\n  alpha: :beta\n")
      write(b_dir, 'de.yml', 'de:' + "\n  beta: :alpha\n")
      backends, errors = AliasChecker.load_backends([a_dir, b_dir])
      report = AliasChecker.analyze(backends, errors, defaults: [])
      assert_equal 0, report.cycles.size
      assert report.results.all? { |r| r.status == :dangling }
    end
  end

  def test_explicit_fallback_mapping
    Dir.mktmpdir do |root|
      a_dir = File.join(root, 'a'); b_dir = File.join(root, 'b')
      FileUtils.mkdir_p([a_dir, b_dir])
      write(a_dir, 'en.yml', 'en:' + "\n  shared: 'EN'\n")
      write(b_dir, 'ca.yml', 'ca:' + "\n  greet: :shared\n")
      backends, errors = AliasChecker.load_backends([a_dir, b_dir])

      # without mapping ca can only fall back to its parents (none) -> dangle
      none = AliasChecker.analyze(backends, [], defaults: [])
      assert_equal :dangling, none.results.first.status

      # with ca -> en mapping it resolves
      mapped = AliasChecker.analyze(backends, [], defaults: [],
                                    mappings: { ca: :en })
      assert_equal :ok, mapped.results.first.status
    end
  end

  # ------------------------------------------------------------------
  # dynamic Proc values
  # ------------------------------------------------------------------

  def test_proc_targets_are_dynamic_and_never_ok
    report = checker('rb_backend')
    dyn = by_key(report)[:points_dyn]
    assert_equal :dynamic, dyn.status
    assert_equal 'Proc', dyn.type

    plain = by_key(report)[:plain_alias]
    assert_equal :ok, plain.status
  end

  # ------------------------------------------------------------------
  # read-only behaviour
  # ------------------------------------------------------------------

  def test_does_not_mutate_loaded_hashes_or_call_procs
    called = false
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'en.rb'), <<~RUBY)
        { en: { dyn: ->(locale, opts) { $alias_proc_called.call },
                via: :dyn } }
      RUBY
      $alias_proc_called = -> { called = true }
      backends, errors = AliasChecker.load_backends([dir])
      report = AliasChecker.analyze(backends, errors)
      assert_equal :dynamic, report.results.first.status
      refute called, 'Proc must never be invoked by the static checker'
      # underlying value is still a Proc (was not replaced/called)
      assert_equal Proc, backends.first.files.first.data[:dyn].class
      assert_equal Symbol, backends.first.files.first.data[:via].class
    end
  ensure
    $alias_proc_called = nil
  end

  def test_malformed_file_is_reported_as_load_error_not_raised
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'bad.yml'), "en:\n  - :oops\n bad: [")
      backends, errors = AliasChecker.load_backends([dir])
      refute_empty errors
    end
  end

  private

  # Builds a one-backend report straight from a Ruby hash.
  def build(data)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'en.rb'), data.inspect)
      backends, errors = AliasChecker.load_backends([dir])
      return AliasChecker.analyze(backends, errors)
    end
  end

  def build_two(data_a, data_b)
    Dir.mktmpdir do |root|
      a = File.join(root, 'a'); b = File.join(root, 'b')
      FileUtils.mkdir_p(a); FileUtils.mkdir_p(b)
      File.write(File.join(a, 'en.rb'), data_a.inspect)
      File.write(File.join(b, 'en.rb'), data_b.inspect)
      backends, errors = AliasChecker.load_backends([a, b])
      AliasChecker.analyze(backends, errors)
    end
  end

  def write(dir, name, contents)
    File.write(File.join(dir, name), contents)
  end
end

require 'tmpdir'
require 'fileutils'

class AliasCheckerSemanticsTest < Minitest::Test
  # Hard-won semantics validated against the real I18n implementation by
  # differential fuzzing (see dev notes). These pin the resolver so the
  # subtle backend/fallback interaction cannot silently regress.

  def backend_from(data)
    I18n::AliasChecker::FileEntry.new(path: nil, locale: @loc, data: data)
  end

  def analyze_for(backends_data, defaults: [:en])
    backends = backends_data.map do |bd|
      files = bd.map { |loc, data| I18n::AliasChecker::FileEntry.new(
        path: nil, locale: loc, data: data) }
      I18n::AliasChecker::Backend.new(name: 'b', files: files)
    end
    I18n::AliasChecker.analyze(backends, [], defaults: defaults)
  end

  def resolve(backends_data, locale, key, defaults: [:en])
    backends = backends_data.map do |bd|
      I18n::AliasChecker::Backend.new(name: 'b', files: bd.map { |l, d|
        I18n::AliasChecker::FileEntry.new(path: nil, locale: l, data: d) })
    end
    engine = I18n::AliasChecker::Engine.new(
      backends, I18n::AliasChecker::Fallbacks.new(defaults: defaults))
    engine.resolve(locale, key)
  end

  def test_backend_priority_beats_fallback_locale
    # backend 0 has no de.b, but its en.b scalar wins over backend 1's
    # de.b link (chain is tried before moving between backends).
    out = resolve(
      [{ en: { b: 42 } }, { de: { b: :d, d: :e, e: :a }, en: { a: :a } }],
      :de, :b)
    assert_equal :ok, out[:status]
    assert_equal 'Integer', out[:type]
  end

  def test_later_backend_better_locale_scalar_replaces_earlier_fallback_hash
    # backend 0 only supplies en.ns (a Hash via fallback); backend 1 has
    # a concrete de.ns scalar. The scalar replaces the namespace.
    out = resolve(
      [{ en: { ns: { x: 'ENX' } } }, { de: { ns: 'DE_SCALAR' } }],
      :de, :ns)
    assert_equal :ok, out[:status]
    assert_equal 'String', out[:type]
  end

  def test_explicit_nil_falls_through_chain
    out = resolve(
      [{ en: { z: nil } }, { en: { z: 'later' } }],
      :en, :z, defaults: [])
    assert_equal :ok, out[:status]
    assert_equal 'String', out[:type]
  end

  def test_alias_to_proc_is_dynamic
    out = resolve([{ en: { a: :p, p: proc { |_, _| :x } } }], :en, :a,
                  defaults: [])
    assert_equal :dynamic, out[:status]
  end

  def test_cross_backend_cycle_records_every_hop_with_backend_and_file
    Dir.mktmpdir do |root|
      a = File.join(root, 'a'); g = File.join(root, 'g')
      FileUtils.mkdir_p([a, g])
      write = lambda { |dir, c| File.write(File.join(dir, 'en.rb'), c) }
      write.call(a, { en: { x: :y } }.inspect)
      write.call(g, { en: { y: :x } }.inspect)
      backends, errors = I18n::AliasChecker.load_backends([a, g])
      report = I18n::AliasChecker.analyze(backends, errors, defaults: [])
      assert_equal 1, report.cycles.size
      group = report.cycles.first
      assert_equal [:'x', :'y', :'x'], group.cycle
      backends_seen = group.entries.flat_map(&:hops).map(&:backend).sort.uniq
      assert_equal [0, 1], backends_seen
    end
  end

  def test_nested_dotted_alias_resolves_across_namespace
    out = resolve([{ en: { ns: :'other.space',
                           other: { space: { leaf: 7 } } } }],
                  :en, :'ns.leaf', defaults: [])
    assert_equal :ok, out[:status]
    assert_equal 'Integer', out[:type]
  end

  def test_dangling_target_type_is_nil_terminal_type_is_reported
    out_ok = resolve([{ en: { a: :b, b: false } }], :en, :a, defaults: [])
    assert_equal :ok, out_ok[:status]
    assert_equal 'FalseClass', out_ok[:type]
  end
end

class AliasCheckerGlobalStateTest < Minitest::Test
  # The checker must not depend on, or mutate, the global I18n runtime -
  # no backends instantiated, no translation cache, no Proc evaluation.
  def test_runs_without_loading_i18n_runtime
    # Run the library in a bare subprocess using only stdlib (yaml/json),
    # pointing at the on-disk healthy fixture. `i18n.rb` is never loaded.
    lib = File.expand_path('../lib', __dir__)
    fixture = File.join(File.dirname(__FILE__), 'test_data', 'alias_check',
                        'healthy')
    code = <<~RUBY
      $LOAD_PATH.unshift(#{lib.inspect})
      require 'i18n/alias_checker'
      backends, errors = I18n::AliasChecker.load_backends([#{fixture.inspect}])
      report = I18n::AliasChecker.analyze(backends, errors, defaults: [])
      ok = report.oks.size == 3 && report.load_errors.empty? &&
           report.cycles.empty? && report.danglings.empty?
      exit(ok ? 0 : 1)
    RUBY
    system(RbConfig.ruby, '-e', code, out: File::NULL)
    assert $?.success?, 'checker should run standalone without i18n runtime'
  end
end
