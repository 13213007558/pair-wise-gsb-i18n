require 'test_helper'

class I18nBackendPseudoLocaleTest < I18n::TestCase
  class Backend < I18n::Backend::Simple
    include I18n::Backend::PseudoLocale
  end

  def setup
    super
    I18n::PseudoLocale.reset!
    I18n::PseudoLocale.configure do |config|
      config.locales = [:ps]
      config.expansion_ratio = 1.4
    end
    I18n.backend = Backend.new
    store_translations(:en,
      :greeting => 'Hi %{name}',
      :inbox => { :one => 'one message', :other => '%{count} messages' },
      :link => %{Go to <a href="https://example.com/orders/ORD-12345">your order</a>},
      :nested => { :deep => { :title => 'Hello World' } }
    )
    store_translations(:ps, :local => 'Local pseudo entry')
  end

  def teardown
    super
    I18n::PseudoLocale.reset!
  end

  test "pseudo locale expands source text and wraps it in markers" do
    result = I18n.t(:greeting, :locale => :ps, :name => 'David')
    assert result.start_with?('⟦')
    assert result.end_with?('⟧')
  end

  test "interpolated user values are not expanded or rewritten" do
    assert_equal '⟦Ħï David⟧', I18n.t(:greeting, :locale => :ps, :name => 'David')
  end

  test "pluralization still runs through the normal I18n flow" do
    one = I18n.t(:inbox, :locale => :ps, :count => 1)
    assert one.start_with?('⟦')
    refute_includes one, '1'
    other = I18n.t(:inbox, :locale => :ps, :count => 5)
    assert_includes other, '5'
    refute_includes other, '%{count}'
  end

  test "links and business ids are not rewritten" do
    result = I18n.t(:link, :locale => :ps)
    assert_includes result, 'https://example.com/orders/ORD-12345'
    assert_includes result, '<a href="https://example.com/orders/ORD-12345">'
  end

  test "falls back to the default locale source text when the pseudo locale has no entry" do
    result = I18n.t(:greeting, :locale => :ps, :name => 'David')
    assert_includes result, 'David'
    assert result.start_with?('⟦')
  end

  test "translations stored for the pseudo locale itself are transformed too" do
    result = I18n.t(:local, :locale => :ps)
    assert result.start_with?('⟦')
    refute_includes result, 'Local'
  end

  test "subtree lookups are pseudo localized recursively" do
    subtree = I18n.t(:nested, :locale => :ps)
    assert subtree[:deep][:title].start_with?('⟦')
  end

  test "non pseudo locales are left untouched" do
    assert_equal 'Hi David', I18n.t(:greeting, :locale => :en, :name => 'David')
  end

  test "repeated generation for the same templates is consistent" do
    first = I18n.t(:greeting, :locale => :ps, :name => 'David')
    assert_equal first, I18n.t(:greeting, :locale => :ps, :name => 'David')
    assert_equal first, I18n.t(:greeting, :locale => :ps, :name => 'David')
  end

  test "missing keys still raise MissingTranslation for pseudo locales" do
    exception = assert_raises(I18n::MissingTranslationData) do
      I18n.t(:missing_key, :locale => :ps, :raise => true)
    end
    assert_equal :missing_key, exception.key
  end
end
