require 'test_helper'

class I18nBackendPrefixShardsTest < I18n::TestCase
  # A loader that counts how often it was called.
  class CountingLoader
    attr_reader :calls

    def initialize(data = {})
      @data  = data
      @calls = 0
    end

    def call
      @calls += 1
      @data
    end
  end

  # A loader that blocks until it is explicitly released, so tests can
  # observe concurrent loads. #entered signals that the loader was called.
  class BlockingLoader
    attr_reader :calls, :entered

    def initialize(data = {})
      @data    = data
      @calls   = 0
      @entered = Queue.new
      @release = Queue.new
    end

    def call
      @calls += 1
      @entered << true
      @release.pop
      @data
    end

    def release!
      @release << true
    end
  end

  def setup
    super
    @backend = I18n::Backend::PrefixShards.new
    I18n.backend = @backend
  end

  def register(locale, prefix, data)
    loader = CountingLoader.new(data)
    @backend.register(locale, prefix, loader)
    loader
  end

  test "lookup only loads the shard covering the requested key" do
    billing = register(:en, "billing", :title => "Billing")
    catalog = register(:en, "catalog", :title => "Catalog")
    admin   = register(:en, "admin",   :title => "Admin")

    assert_equal "Billing", I18n.t(:"billing.title")

    assert_equal 1, billing.calls
    assert_equal 0, catalog.calls
    assert_equal 0, admin.calls
    assert_equal ["en.billing"], @backend.loaded_shards
  end

  test "a loaded shard is not loaded again" do
    billing = register(:en, "billing", :title => "Billing", :subtitle => "Sub")

    I18n.t(:"billing.title")
    I18n.t(:"billing.subtitle")

    assert_equal 1, billing.calls
  end

  test "longest prefix wins" do
    billing  = register(:en, "billing",          :invoices => { :title => "From billing" })
    invoices = register(:en, "billing.invoices", :title => "From invoices")

    assert_equal "From invoices", I18n.t(:"billing.invoices.title")
    assert_equal 0, billing.calls
    assert_equal 1, invoices.calls
  end

  test "parent node lookup merges child shards" do
    billing  = register(:en, "billing",          :title => "Billing")
    invoices = register(:en, "billing.invoices", :title => "Invoices")
    payments = register(:en, "billing.payments", :title => "Payments")
    catalog  = register(:en, "catalog",          :title => "Catalog")

    assert_equal(
      { :title => "Billing", :invoices => { :title => "Invoices" }, :payments => { :title => "Payments" } },
      I18n.t(:billing)
    )
    assert_equal 1, billing.calls
    assert_equal 1, invoices.calls
    assert_equal 1, payments.calls
    assert_equal 0, catalog.calls
  end

  test "parent node lookup works when only child shards are registered" do
    register(:en, "billing.invoices", :title => "Invoices")

    assert_equal({ :invoices => { :title => "Invoices" } }, I18n.t(:billing))
  end

  test "deeper shards win on conflicts when merging" do
    register(:en, "billing",          :invoices => { :title => "From billing", :other => "other" })
    register(:en, "billing.invoices", :title => "From invoices")

    assert_equal(
      { :invoices => { :title => "From invoices", :other => "other" } },
      I18n.t(:billing)
    )
  end

  test "leaf results shadow deeper shards and do not load them" do
    register(:en, "billing", :invoices => "leaf")
    overdue = register(:en, "billing.invoices.overdue", :title => "Overdue")

    assert_equal "leaf", I18n.t(:"billing.invoices")
    assert_equal 0, overdue.calls
  end

  test "missing keys under a registered prefix only load the covering shard" do
    billing = register(:en, "billing", :title => "Billing")
    catalog = register(:en, "catalog", :title => "Catalog")

    assert_nil I18n.t(:"billing.nope", :default => nil)
    assert_equal 1, billing.calls
    assert_equal 0, catalog.calls
  end

  test "missing keys outside all prefixes do not trigger any load" do
    billing = register(:en, "billing", :title => "Billing")
    catalog = register(:en, "catalog", :title => "Catalog")

    assert_nil I18n.t(:"does.not.exist", :default => nil)
    assert_equal 0, billing.calls
    assert_equal 0, catalog.calls
    assert_equal [], @backend.loaded_shards
  end

  test "aliases resolve across shards" do
    register(:en, "billing", :title => :"catalog.shared_title")
    catalog = register(:en, "catalog", :shared_title => "Shared Title")

    assert_equal "Shared Title", I18n.t(:"billing.title")
    assert_equal 1, catalog.calls
  end

  test "aliases within a shard resolve" do
    register(:en, "billing", :title => "Billing", :heading => :"billing.title")

    assert_equal "Billing", I18n.t(:"billing.heading")
  end

  test "pluralization works" do
    register(:en, "billing", :inbox => { :one => "one message", :other => "%{count} messages" })

    assert_equal "one message", I18n.t(:"billing.inbox", :count => 1)
    assert_equal "2 messages", I18n.t(:"billing.inbox", :count => 2)
  end

  test "interpolation works" do
    register(:en, "billing", :welcome => "Hello %{name}")

    assert_equal "Hello Bob", I18n.t(:"billing.welcome", :name => "Bob")
  end

  test "locale fallbacks load the fallback locale's shard" do
    @backend.extend(I18n::Backend::Fallbacks)

    de = register(:de, "billing", :title => "Abrechnung")
    en = register(:en, "billing", :title => "Billing", :subtitle => "Sub")
    I18n.fallbacks = I18n::Locale::Fallbacks.new(:de => :en)

    assert_equal "Abrechnung", I18n.t(:"billing.title", :locale => :de)
    assert_equal "Sub", I18n.t(:"billing.subtitle", :locale => :de)
    assert_equal 1, de.calls
    assert_equal 1, en.calls
  end

  test "root prefix shards cover top level keys" do
    root    = register(:en, "", :hello => "Hello")
    catalog = register(:en, "catalog", :title => "Catalog")

    assert_equal "Hello", I18n.t(:hello)
    assert_equal 1, root.calls
    assert_equal 0, catalog.calls
  end

  test "concurrent first lookups share a single load" do
    loader = BlockingLoader.new(:title => "Billing")
    @backend.register(:en, "billing", loader)

    threads = 5.times.map do
      Thread.new { I18n.t(:"billing.title") }
    end

    loader.entered.pop # wait until the first load started
    sleep 0.1          # give the other threads a chance to pile up
    5.times { loader.release! }

    assert_equal ["Billing"] * 5, threads.map(&:value)
    assert_equal 1, loader.calls
  end

  test "a failing loader propagates, exposes nothing and can be retried" do
    calls = 0
    @backend.register(:en, "billing", lambda {
      calls += 1
      raise "boom" if calls == 1
      { :title => "Billing" }
    })

    assert_raises(RuntimeError) { I18n.t(:"billing.title") }
    assert_equal [], @backend.loaded_shards

    assert_equal "Billing", I18n.t(:"billing.title")
    assert_equal 2, calls
  end

  test "a loader returning a non Hash raises InvalidLocaleData" do
    @backend.register(:en, "billing", lambda { "nope" })

    assert_raises(I18n::InvalidLocaleData) { I18n.t(:"billing.title") }
  end

  test "reload_shard! only resets the given shard" do
    billing = register(:en, "billing", :title => "Billing")
    catalog = register(:en, "catalog", :title => "Catalog")

    I18n.t(:"billing.title")
    I18n.t(:"catalog.title")

    assert @backend.reload_shard!(:en, "billing")
    assert_equal ["en.catalog"], @backend.loaded_shards

    assert_equal "Billing", I18n.t(:"billing.title")
    assert_equal "Catalog", I18n.t(:"catalog.title")
    assert_equal 2, billing.calls
    assert_equal 1, catalog.calls
  end

  test "reload_shard! returns false for unknown shards" do
    register(:en, "billing", :title => "Billing")

    refute @backend.reload_shard!(:en, "catalog")
    refute @backend.reload_shard!(:de, "billing")
  end

  test "reload! resets all shards and eagerly stored translations" do
    billing = register(:en, "billing", :title => "Billing")
    catalog = register(:en, "catalog", :title => "Catalog")
    @backend.store_translations(:en, :stored => "stored")

    I18n.t(:"billing.title")
    I18n.t(:"catalog.title")
    @backend.reload!
    assert_equal [], @backend.loaded_shards

    I18n.t(:"billing.title")
    I18n.t(:"catalog.title")
    assert_equal 2, billing.calls
    assert_equal 2, catalog.calls
    assert_nil I18n.t(:stored, :default => nil)
  end

  test "eager_load! loads all shards" do
    billing = register(:en, "billing", :title => "Billing")
    catalog = register(:de, "catalog", :title => "Katalog")

    @backend.eager_load!

    assert_equal 1, billing.calls
    assert_equal 1, catalog.calls
    assert_equal ["de.catalog", "en.billing"], @backend.loaded_shards.sort
  end

  test "store_translations acts as a fallback layer that never triggers loads" do
    billing = register(:en, "billing", :title => "Billing")
    @backend.store_translations(:en, :other => "Other")

    assert_equal "Other", I18n.t(:other)
    assert_equal 0, billing.calls
  end

  test "available_locales comes from the manifest and stored translations" do
    register(:en, "billing", :title => "Billing")
    register(:de, "catalog", :title => "Katalog")
    @backend.store_translations(:fr, :foo => "bar")

    assert_equal [:de, :en, :fr], @backend.available_locales.sort
  end

  test "registered? reflects the manifest" do
    @backend.register(:en, "billing", CountingLoader.new)

    assert @backend.registered?(:en, "billing")
    refute @backend.registered?(:en, "catalog")
    refute @backend.registered?(:de, "billing")
  end

  test "re-registering a shard replaces it" do
    register(:en, "billing", :title => "Old")
    assert_equal "Old", I18n.t(:"billing.title")

    register(:en, "billing", :title => "New")
    assert_equal "New", I18n.t(:"billing.title")
  end

  test "register requires a loader" do
    assert_raises(ArgumentError) { @backend.register(:en, "billing") }
  end

  test "exists? works with shards" do
    register(:en, "billing", :title => "Billing")

    assert I18n.exists?(:"billing.title")
    refute I18n.exists?(:"billing.nope")
    refute I18n.exists?(:"nope.nope")
  end
end
