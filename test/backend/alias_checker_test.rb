require 'test_helper'
require 'i18n/backend/alias_checker'

class I18nBackendAliasCheckerTest < I18n::TestCase
  def setup
    super
    @root = File.join(Dir.mktmpdir('i18n-alias-check-'), 'backends')
    @dirs = []
    3.times { |i| make_backend_dir(i) }
  end

  def teardown
    FileUtils.rm_rf(File.dirname(@root)) if @root
    super
  end

  test "resolves a simple alias chain and reports the terminal type" do
    write(0, 'en.yml', <<~YML)
      en:
        first: :second
    YML
    write(1, 'en.yml', <<~YML)
      en:
        second: "the string"
    YML

    finding = check(query: :en).find { |f| f.alias_key == 'first' }
    result = result(finding, :en)

    assert_equal :ok, result.status
    assert_equal :String, result.terminal_type
    assert_match(/second/, result.hops.map(&:to_s).join)
    assert_includes result.terminal_file.to_s, File.join('1', 'en.yml')
  end

  test "reports a self-referencing cycle within one file" do
    write(0, 'en.yml', <<~YML)
      en:
        loop: :loop
    YML

    result = result_for('loop', :en)
    assert_equal :cycle, result.status
    assert result.ring.any? { |line| line.include?('CYCLE') }
    refute_predicate build_checker([[backend_dir(0)]], query: [:en]), :healthy?
  end

  test "cycle that only forms across two backends is flagged; each backend alone is cycle-free" do
    write(0, 'en.yml', <<~YML)
      en:
        alpha: :beta
    YML
    write(1, 'en.yml', <<~YML)
      en:
        beta: :alpha
    YML

    # Individually neither backend closes the loop: no cycle, the link just
    # points into the other (not loaded) backend.
    alone0 = build_checker([[backend_dir(0)]], query: [:en]).check
    alone1 = build_checker([[backend_dir(1)]], query: [:en]).check
    assert alone0.none? { |f| f.results.any? { |r| r.status == :cycle } }
    assert alone1.none? { |f| f.results.any? { |r| r.status == :cycle } }

    # Combined, the chain closes and is reported.
    combined = build_checker([[backend_dir(0)], [backend_dir(1)]], query: [:en])
    refute_predicate combined, :healthy?
    statuses = combined.check.flat_map(&:results).map(&:status)
    assert_includes statuses, :cycle

    alpha = result_for('alpha', :en, combined)
    assert alpha.hops.any? { |h| h.backend == '#0' }
    assert alpha.hops.any? { |h| h.backend == '#1' }
    assert alpha.ring.any? { |line| line.include?('CYCLE') }
  end

  test "reports dangling references" do
    write(0, 'en.yml', <<~YML)
      en:
        broken: :does_not_exist
    YML

    result = result_for('broken', :en)
    assert_equal :dangling, result.status
    refute_predicate build_checker([[backend_dir(0)]], query: [:en]), :healthy?
  end

  test "respects backend priority: first backend wins" do
    write(0, 'en.yml', "en:\n  target: from_first\n")
    write(1, 'en.yml', "en:\n  target: from_second\n  src: :target\n")

    result = result_for('src', :en)
    assert_equal :ok, result.status
    assert_equal :String, result.terminal_type
    assert result.hops.any? { |h| h.kind.include?('terminal') && h.backend == '#0' }, result.hops.inspect
  end

  test "namespace hashes are merged across backends with leftmost priority" do
    write(0, 'en.yml', "en:\n  ns:\n    link: :other.ns\n    keep: first\n")
    write(1, 'en.yml', "en:\n  other:\n    ns:\n      added: second\n")

    # The alias `ns.link` targets a namespace; terminal type is Hash.
    result = result_for('ns.link', :en)
    assert_equal :ok, result.status
    assert_equal :Hash, result.terminal_type
  end

  test "mid-path alias descending into another backend resolves remaining segments" do
    write(0, 'en.yml', "en:\n  x: :\"a.b\"\n")
    write(1, 'en.yml', "en:\n  a: :other\n  other:\n    b: deep-value\n")

    result = result_for('x', :en)
    assert_equal :ok, result.status
    assert_equal :String, result.terminal_type
    assert_equal 'deep-value', resolve_real('x', :en)
  end

  test "follows locale fallback order and restarts each link from the original locale" do
    write(0, 'de.yml', "de:\n  greet: :hello\n")
    write(1, 'en.yml', "en:\n  hello: Hello!\n")

    # de falls back to en; the link restarts from de and still reaches en.
    checker = build_checker([[backend_dir(0)], [backend_dir(1)]], query: [:de], defaults: [:en])
    result = checker.check.find { |f| f.alias_key == 'greet' }.results.first
    assert_equal :ok, result.status
    assert result.hops.any? { |h| h.locale == :en && h.key == 'hello' }

    # Without fallbacks the same alias dangles.
    strict = build_checker([[backend_dir(0)], [backend_dir(1)]], query: [:de], defaults: [:en],
                     fallbacks: false)
    strict_result = strict.check.find { |f| f.alias_key == 'greet' }.results.first
    assert_equal :dangling, strict_result.status
  end

  test "explicit nil falls through to the next backend" do
    write(0, 'en.yml', "en:\n  src: :target\n  target: \n")
    write(1, 'en.yml', "en:\n  target: real\n")

    result = result_for('src', :en)
    assert_equal :ok, result.status
    assert_equal :String, result.terminal_type
  end

  test "Proc targets are reported dynamic and are never called" do
    marker = File.join(@root, 'proc_marker')
    write(0, 'en.rb', <<~RB)
      { en: { p: :target_p } }
    RB
    write(1, 'en.rb', <<~RB)
      { en: { target_p: lambda { |_o, **| File.write(#{marker.inspect}, 'called'); 'ran' } } }
    RB

    result = result_for('p', :en)
    assert_equal :dynamic, result.status
    assert_equal :Proc, result.terminal_type
    refute File.exist?(marker), 'the checker must not call a Proc'
  end

  test "symbols nested inside arrays are not treated as aliases" do
    write(0, 'en.yml', "en:\n  plural:\n    - :not_a_link\n")
    assert_predicate build_checker([[backend_dir(0)]], query: [:en]), :healthy?
  end

  test "does not mutate global I18n state" do
    write(0, 'en.yml', "en:\n  a: :b\n  b: 'B'\n")

    I18n.backend.store_translations(:en, { untouched: 'real' })
    backend_id = I18n.backend.object_id
    load_path = I18n.load_path.dup

    build_checker([[backend_dir(0)]], query: [:en]).check

    assert_equal backend_id, I18n.backend.object_id
    assert_equal load_path, I18n.load_path
    assert_nil I18n.backend.send(:lookup, :en, :a)
    assert_equal 'real', catch(:exception) { I18n.t(:untouched, locale: :en) }
  end

  test "JSON string values are not mistaken for symbol links" do
    write(0, 'en.json', JSON.generate({ en: { a: ':b' } }))
    findings = build_checker([[backend_dir(0)]], query: [:en]).check
    assert_empty findings.select { |f| f.alias_key == 'a' }
  end

  test "multiple frozen files are merged into one backend without errors" do
    write(0, 'a.yml', "en:\n  one: :target\n")
    write(0, 'b.yml', "en:\n  target: merged-value\n  two: fine\n")
    result = result_for('one', :en)
    assert_equal :ok, result.status
    assert_equal :String, result.terminal_type
  end

  private

  def make_backend_dir(i)
    dir = File.join(@root, i.to_s)
    FileUtils.mkdir_p(dir)
    @dirs[i] = dir
  end

  def backend_dir(i)
    @dirs[i]
  end

  def write(i, name, contents)
    File.write(File.join(backend_dir(i), name), contents)
  end

  def build_checker(groups, query:, defaults: [:en], mappings: nil, fallbacks: true)
    I18n::Backend::AliasChecker.new(
      backend_dirs: groups,
      fallback_mapping: mappings,
      default_locales: defaults,
      query_locales: query,
      fallbacks: fallbacks
    )
  end

  def check(query: :en, groups: nil)
    groups ||= @dirs.each_with_index.map { |_d, i| [@dirs[i]] }
    build_checker(groups, query: Array(query)).check
  end

  def result(finding, locale)
    finding.results.find { |r| r.locale == locale }
  end

  def result_for(key, locale, checker_instance = nil)
    instance = checker_instance || build_checker(@dirs.each_with_index.map { |_, i| [@dirs[i]] },
                                          query: [locale])
    finding = instance.check.find { |f| f.alias_key == key }
    assert finding, "expected a finding for #{key}"
    finding.results.find { |r| r.locale == locale }
  end

  # Builds the equivalent real Chain+Fallbacks backend and translates, used to
  # confirm the checker mirrors runtime behavior. Files are re-loaded into a
  # throwaway backend so the global test backend stays untouched.
  def resolve_real(key, locale)
    backend_class = Class.new(I18n::Backend::Simple) { include I18n::Backend::Fallbacks }
    members = @dirs.map do |d|
      b = backend_class.new
      Dir.glob(File.join(d, '*')).each { |f| b.load_translations(f) }
      b
    end
    chain = I18n::Backend::Chain.new(*members)
    I18n.fallbacks = I18n::Locale::Fallbacks.new(:en)
    I18n.backend = chain # links re-enter the chain via global I18n.translate
    catch(:exception) { I18n.t(key, locale: locale) }
  end
end
