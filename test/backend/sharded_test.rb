require 'test_helper'

class I18nBackendShardedTest < I18n::TestCase
  # A shard loader that counts its calls, can be blocked on a gate
  # (to coordinate concurrent tests) and can be told to fail once.
  class CountingLoader
    def initialize(data = {})
      @data = data
      @calls = 0
      @entered = Queue.new
      @gate = nil
      @error = nil
      @lock = Mutex.new
    end

    def call
      @lock.synchronize { @calls += 1 }
      @entered << true
      @gate.pop if @gate
      if @error
        error, @error = @error, nil
        raise error
      end
      @data
    end

    def calls
      @lock.synchronize { @calls }
    end

    def data=(data)
      @data = data
    end

    # The next call (and only that one) raises the given error.
    def fail_with(error)
      @error = error
    end

    # Block inside #call until #release! is called.
    def block!
      @gate = Queue.new
    end

    def release!
      @gate << true
    end

    # Waits until a call has entered the loader.
    def wait_until_entered
      @entered.pop
    end
  end

  class BackendWithFallbacks < I18n::Backend::Sharded
    include I18n::Backend::Fallbacks
  end

  def setup
    super
    @backend = I18n::Backend::Sharded.new
    I18n.backend = @backend
  end

  test "loads only the shard covering the queried key" do
    billing = CountingLoader.new('title' => 'Billing')
    catalog = CountingLoader.new('title' => 'Catalog')
    @backend.register(:en, 'billing', billing)
    @backend.register(:en, 'catalog', catalog)

    assert_equal 'Billing', I18n.t('billing.title', locale: :en)
    assert_equal 1, billing.calls
    assert_equal 0, catalog.calls
  end

  test "loads each shard only once" do
    billing = CountingLoader.new('title' => 'Billing', 'subtitle' => 'Bills')
    @backend.register(:en, 'billing', billing)

    assert_equal 'Billing', I18n.t('billing.title', locale: :en)
    assert_equal 'Bills', I18n.t('billing.subtitle', locale: :en)
    assert_equal 1, billing.calls
  end

  test "longest prefix wins" do
    billing = CountingLoader.new('invoices' => { 'title' => 'From billing' })
    invoices = CountingLoader.new('title' => 'From invoices')
    @backend.register(:en, 'billing', billing)
    @backend.register(:en, 'billing.invoices', invoices)

    assert_equal 'From invoices', I18n.t('billing.invoices.title', locale: :en)
    assert_equal 0, billing.calls
    assert_equal 1, invoices.calls
  end

  test "parent key lookup merges child shards" do
    invoices = CountingLoader.new('title' => 'Invoices')
    payments = CountingLoader.new('title' => 'Payments')
    @backend.register(:en, 'billing.invoices', invoices)
    @backend.register(:en, 'billing.payments', payments)

    assert_equal(
      { invoices: { title: 'Invoices' }, payments: { title: 'Payments' } },
      I18n.t('billing', locale: :en)
    )
    assert_equal 1, invoices.calls
    assert_equal 1, payments.calls
  end

  test "aliases (symbol links) resolve across shards" do
    billing = CountingLoader.new('shortcut' => :'catalog.name')
    catalog = CountingLoader.new('name' => 'Rockware')
    @backend.register(:en, 'billing', billing)
    @backend.register(:en, 'catalog', catalog)

    assert_equal 'Rockware', I18n.t('billing.shortcut', locale: :en)
    assert_equal 1, billing.calls
    assert_equal 1, catalog.calls
  end

  test "pluralization works within a shard" do
    billing = CountingLoader.new('invoices' => { 'one' => 'one invoice', 'other' => '%{count} invoices' })
    @backend.register(:en, 'billing', billing)

    assert_equal 'one invoice', I18n.t('billing.invoices', locale: :en, count: 1)
    assert_equal '3 invoices', I18n.t('billing.invoices', locale: :en, count: 3)
    assert_equal 1, billing.calls
  end

  test "locale fallbacks keep working" do
    backend = BackendWithFallbacks.new
    I18n.backend = backend
    en = CountingLoader.new('title' => 'Billing')
    backend.register(:en, 'billing', en)
    I18n.fallbacks = I18n::Locale::Fallbacks.new(de: [:en])

    assert_equal 'Billing', I18n.t('billing.title', locale: :de)
    assert_equal 1, en.calls
  end

  test "concurrent first lookups share a single load" do
    billing = CountingLoader.new('title' => 'Billing')
    billing.block!
    @backend.register(:en, 'billing', billing)

    threads = 5.times.map { Thread.new { I18n.t('billing.title', locale: :en) } }
    billing.wait_until_entered
    sleep 0.1 # give the other threads a chance to pile up on the shard
    assert_equal 1, billing.calls

    billing.release!
    assert_equal ['Billing'] * 5, threads.map(&:value)
    assert_equal 1, billing.calls
  end

  test "a blocked shard does not block other shards" do
    billing = CountingLoader.new('title' => 'Billing')
    catalog = CountingLoader.new('title' => 'Catalog')
    billing.block!
    @backend.register(:en, 'billing', billing)
    @backend.register(:en, 'catalog', catalog)

    thread = Thread.new { I18n.t('billing.title', locale: :en) }
    billing.wait_until_entered

    assert_equal 'Catalog', I18n.t('catalog.title', locale: :en)
    assert_equal 1, catalog.calls

    billing.release!
    assert_equal 'Billing', thread.value
  end

  test "a failed load can be retried and exposes no half-loaded results" do
    billing = CountingLoader.new('title' => 'Billing')
    billing.fail_with(StandardError.new('boom'))
    @backend.register(:en, 'billing', billing)

    assert_raises(StandardError) { I18n.t('billing.title', locale: :en) }
    translations = @backend.instance_variable_get(:@translations)
    assert translations.nil? || translations.empty?, 'failed load must not store partial data'

    assert_equal 'Billing', I18n.t('billing.title', locale: :en)
    assert_equal 2, billing.calls
  end

  test "reload_shard reloads only that shard" do
    billing = CountingLoader.new('title' => 'Billing v1')
    catalog = CountingLoader.new('title' => 'Catalog')
    @backend.register(:en, 'billing', billing)
    @backend.register(:en, 'catalog', catalog)

    assert_equal 'Billing v1', I18n.t('billing.title', locale: :en)
    assert_equal 'Catalog', I18n.t('catalog.title', locale: :en)

    billing.data = { 'title' => 'Billing v2' }
    @backend.reload_shard(:en, 'billing')

    assert_equal 'Catalog', I18n.t('catalog.title', locale: :en)
    assert_equal 1, catalog.calls
    assert_equal 'Billing v2', I18n.t('billing.title', locale: :en)
    assert_equal 2, billing.calls
  end

  test "reload_shard on a nested prefix leaves sibling shards untouched" do
    invoices = CountingLoader.new('title' => 'Invoices v1')
    payments = CountingLoader.new('title' => 'Payments')
    @backend.register(:en, 'billing.invoices', invoices)
    @backend.register(:en, 'billing.payments', payments)

    I18n.t('billing', locale: :en)

    invoices.data = { 'title' => 'Invoices v2' }
    @backend.reload_shard(:en, 'billing.invoices')

    assert_equal 'Payments', I18n.t('billing.payments.title', locale: :en)
    assert_equal 1, payments.calls
    assert_equal 'Invoices v2', I18n.t('billing.invoices.title', locale: :en)
    assert_equal 2, invoices.calls
  end

  test "keys not covered by the manifest do not trigger any load" do
    billing = CountingLoader.new('title' => 'Billing')
    catalog = CountingLoader.new('title' => 'Catalog')
    @backend.register(:en, 'billing', billing)
    @backend.register(:en, 'catalog', catalog)

    assert_equal 'default', I18n.t('does.not.exist', locale: :en, default: 'default')
    assert_equal 0, billing.calls
    assert_equal 0, catalog.calls
  end

  test "a missing key inside a covered prefix loads only that shard" do
    billing = CountingLoader.new('title' => 'Billing')
    catalog = CountingLoader.new('title' => 'Catalog')
    @backend.register(:en, 'billing', billing)
    @backend.register(:en, 'catalog', catalog)

    assert_equal 'default', I18n.t('billing.missing', locale: :en, default: 'default')
    assert_equal 1, billing.calls
    assert_equal 0, catalog.calls
  end

  test "reload! clears all shards" do
    billing = CountingLoader.new('title' => 'Billing')
    catalog = CountingLoader.new('title' => 'Catalog')
    @backend.register(:en, 'billing', billing)
    @backend.register(:en, 'catalog', catalog)

    I18n.t('billing.title', locale: :en)
    I18n.t('catalog.title', locale: :en)
    @backend.reload!

    assert_equal 'Billing', I18n.t('billing.title', locale: :en)
    assert_equal 'Catalog', I18n.t('catalog.title', locale: :en)
    assert_equal 2, billing.calls
    assert_equal 2, catalog.calls
  end

  test "manifest can be passed to the constructor and eager_load! loads all shards" do
    billing = CountingLoader.new('title' => 'Billing')
    catalog = CountingLoader.new('title' => 'Catalog')
    backend = I18n::Backend::Sharded.new(en: { 'billing' => billing, 'catalog' => catalog })
    I18n.backend = backend

    assert_equal 0, billing.calls
    backend.eager_load!
    assert_equal 1, billing.calls
    assert_equal 1, catalog.calls
    assert_equal 'Billing', I18n.t('billing.title', locale: :en)
    assert_equal 1, billing.calls
  end

  test "available_locales comes from the manifest without loading shards" do
    billing = CountingLoader.new('title' => 'Billing')
    @backend.register(:en, 'billing', billing)
    @backend.register(:de, 'billing') { { 'title' => 'Abrechnung' } }

    assert_equal [:de, :en], @backend.available_locales.sort
    assert_equal 0, billing.calls
  end

  test "register accepts a block as loader" do
    @backend.register(:en, 'billing') { { 'title' => 'Billing' } }
    assert_equal 'Billing', I18n.t('billing.title', locale: :en)
  end

  test "register rejects duplicate prefixes and non-callable loaders" do
    @backend.register(:en, 'billing') { {} }
    assert_raises(ArgumentError) { @backend.register(:en, 'billing') { {} } }
    assert_raises(ArgumentError) { @backend.register(:en, 'catalog', 'not callable') }
  end

  test "a loader returning a non-hash raises and can be retried" do
    billing = CountingLoader.new('not a hash')
    @backend.register(:en, 'billing', billing)

    assert_raises(I18n::InvalidLocaleData) { I18n.t('billing.title', locale: :en) }

    billing.data = { 'title' => 'Billing' }
    assert_equal 'Billing', I18n.t('billing.title', locale: :en)
    assert_equal 2, billing.calls
  end
end
