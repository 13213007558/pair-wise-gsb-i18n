require 'test_helper'

class I18nBackendPseudoLocaleTest < I18n::TestCase
  class PseudoBackend < I18n::Backend::Simple
    include I18n::Backend::PseudoLocale
  end

  def setup
    super
    I18n.backend = PseudoBackend.new
    I18n.config.pseudo_locales = [:ps]
    store_translations(:en,
      :foo => 'Hello World',
      :greeting => 'Hello %{name}, welcome!',
      :formatted => 'Progress: %<progress>.1f%% done',
      :escaped => '100%% sure %{name}',
      :inbox => { :one => 'One message', :other => '%{count} messages' },
      :markup => '<a href="https://example.com/orders/ORD-12345">Track order</a> &amp; enjoy',
      :link_text => 'Visit https://example.com/path?q=1 or mail support@example.com today',
      :order => 'Your order ORD-12345 and ticket ABC123 are ready',
      :unsupported => 'Value: %d units',
      :nested => { :inner => 'Deep text' },
      :list => ['First item', 'Second item'],
      :number => 42
    )
  end

  def teardown
    I18n.config.pseudo_locales = []
    I18n.config.pseudo_source_locale = nil
    I18n.config.pseudo_expansion_ratio = nil
    I18n.config.pseudo_markers = nil
    I18n.config.pseudo_character_map = nil
    I18n.config.pseudo_preserve_patterns = nil
    I18n::PseudoLocalizer.clear_unsupported_fragments
    super
  end

  test "pseudo locale expands and replaces characters with markers" do
    result = I18n.t(:foo, :locale => :ps)
    assert_match(/\A⟦.*⟧\z/, result)
    assert_includes result, 'Ħëļļö Ŵöŕļð'
    assert result.length > '⟦Hello World⟧'.length, "expected expansion: #{result.inspect}"
  end

  test "non pseudo locales are served untouched" do
    assert_equal 'Hello World', I18n.t(:foo, :locale => :en)
  end

  test "interpolation placeholders are preserved and user values are not expanded" do
    result = I18n.t(:greeting, :locale => :ps, :name => 'Jürgen')
    assert_includes result, 'Jürgen'
    refute_includes result, 'Ĵüŕğëñ'
    refute_includes result, '%{name}'
    assert_match(/\A⟦.*⟧\z/, result)
  end

  test "format placeholders and escaped percents are preserved" do
    result = I18n.t(:formatted, :locale => :ps, :progress => 12.34)
    assert_includes result, '12.3%'
    refute_includes result, '%<progress>'

    result = I18n.t(:escaped, :locale => :ps, :name => 'Bob')
    assert_includes result, '100%'
    assert_includes result, 'Bob'
  end

  test "pluralization still works through the normal flow" do
    one = I18n.t(:inbox, :locale => :ps, :count => 1)
    other = I18n.t(:inbox, :locale => :ps, :count => 5)
    assert_match(/Öñë/, one) # "One" pseudo-localized
    assert_includes other, '5'
    refute_equal one, other
  end

  test "html tags, entities, urls and business ids are not rewritten" do
    result = I18n.t(:markup, :locale => :ps)
    assert_includes result, '<a href="https://example.com/orders/ORD-12345">'
    assert_includes result, '</a>'
    assert_includes result, '&amp;'
    assert_includes result, 'ORD-12345'

    result = I18n.t(:link_text, :locale => :ps)
    assert_includes result, 'https://example.com/path?q=1'
    assert_includes result, 'support@example.com'

    result = I18n.t(:order, :locale => :ps)
    assert_includes result, 'ORD-12345'
    assert_includes result, 'ABC123'
  end

  test "unsupported format fragments are kept verbatim and queryable" do
    I18n::PseudoLocalizer.clear_unsupported_fragments
    result = I18n.t(:unsupported, :locale => :ps)
    assert_includes result, '%d'

    fragments = I18n::PseudoLocalizer.unsupported_fragments
    assert_equal 1, fragments.size
    assert_equal '%d', fragments.first[:fragment]
    assert_equal 'Value: %d units', fragments.first[:template]

    I18n::PseudoLocalizer.clear_unsupported_fragments
    assert_equal [], I18n::PseudoLocalizer.unsupported_fragments
  end

  test "results are deterministic for repeated translations" do
    first = I18n.t(:greeting, :locale => :ps, :name => 'A')
    second = I18n.t(:greeting, :locale => :ps, :name => 'A')
    assert_equal first, second
    assert_equal first, I18n.pseudo_localize('Hello %{name}, welcome!').sub('%{name}', 'A')
  end

  test "expansion ratio and markers are configurable" do
    I18n.config.pseudo_expansion_ratio = 0
    I18n.config.pseudo_markers = ['[', ']']
    assert_equal '[Ħëļļö Ŵöŕļð]', I18n.t(:foo, :locale => :ps)

    I18n.config.pseudo_expansion_ratio = 1.0
    result = I18n.t(:foo, :locale => :ps)
    assert result.length > '[Ħëļļö Ŵöŕļð]'.length + 5
  end

  test "custom preserve patterns are honored" do
    store_translations(:en, :code => 'Code xyzzy here')
    I18n.config.pseudo_preserve_patterns = [/xyzzy/]
    assert_includes I18n.t(:code, :locale => :ps), 'xyzzy'
  end

  test "source locale is configurable" do
    store_translations(:de, :foo => 'Hallo Welt')
    I18n.config.pseudo_source_locale = :de
    assert_includes I18n.t(:foo, :locale => :ps), 'Ħàļļö Ŵëļţ'
  end

  test "hashes and arrays are pseudo-localized recursively, other values untouched" do
    nested = I18n.t(:nested, :locale => :ps)
    assert_equal [:inner], nested.keys
    assert_match(/\A⟦.*⟧\z/, nested[:inner])

    list = I18n.t(:list, :locale => :ps)
    assert_equal 2, list.size
    assert list.all? { |item| item =~ /\A⟦.*⟧\z/ }

    assert_equal 42, I18n.t(:number, :locale => :ps)
  end

  test "missing translations still raise for pseudo locales" do
    assert_raises(I18n::MissingTranslationData) do
      I18n.t(:missing_key, :locale => :ps, :raise => true)
    end
  end

  test "exists? checks the source locale for pseudo locales" do
    assert I18n.backend.exists?(:ps, :foo)
    refute I18n.backend.exists?(:ps, :missing_key)
  end

  test "defaults are used for pseudo locales" do
    result = I18n.t(:missing_key, :locale => :ps, :default => 'Fallback text')
    assert_match(/\A⟦.*⟧\z/, result)
    assert_includes result, 'Ƒàļļƀàçķ'
  end

  test "pseudo_locale? predicate" do
    assert I18n.pseudo_locale?(:ps)
    assert I18n.pseudo_locale?('ps')
    refute I18n.pseudo_locale?(:en)
    refute I18n.pseudo_locale?(nil)
  end

  test "deep interpolation interpolates user values after pseudo-localization" do
    store_translations(:en, :deep => { :welcome => 'Hi %{name}' })
    result = I18n.t(:deep, :locale => :ps, :name => 'Bob', :deep_interpolation => true)
    assert_includes result[:welcome], 'Bob'
    assert_match(/\A⟦.*⟧\z/, result[:welcome])
  end

  test "caller supplied skip_interpolation is honored" do
    result = I18n.t(:greeting, :locale => :ps, :name => 'Bob', :skip_interpolation => true)
    assert_includes result, '%{name}'
    refute_includes result, 'Bob'
  end
end
