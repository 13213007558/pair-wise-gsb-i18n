require 'test_helper'

class I18nPseudoLocaleTest < I18n::TestCase
  def setup
    super
    I18n::PseudoLocale.reset!
    I18n::PseudoLocale.configure do |config|
      config.locales = [:ps]
      config.expansion_ratio = 1.5
    end
  end

  def teardown
    super
    I18n::PseudoLocale.reset!
  end

  def transform(string)
    I18n::PseudoLocale.transform(string)
  end

  test "wraps the result in configurable markers" do
    I18n::PseudoLocale.configure do |config|
      config.left_marker = '[[['
      config.right_marker = ']]]'
    end
    result = transform('Hello')
    assert result.start_with?('[[[')
    assert result.end_with?(']]]')
  end

  test "replaces latin letters with accented look-alikes" do
    result = transform('Hello')
    refute_match(/[Helo]/, result.sub(/\A⟦/, '').sub(/⟧\z/, ''))
    assert_includes result, 'Ħ'
  end

  test "expands text deterministically according to the configured ratio" do
    source = 'Hello brave new world'
    result = transform(source)
    inner = result[I18n::PseudoLocale.configuration.left_marker.length..-(I18n::PseudoLocale.configuration.right_marker.length + 1)]
    assert inner.length >= source.length * 1.4
  end

  test "expansion ratio is configurable" do
    I18n::PseudoLocale.configure { |config| config.expansion_ratio = 2.0 }
    big = transform('Hello brave new world')
    I18n::PseudoLocale.configure { |config| config.expansion_ratio = 1.0 }
    small = transform('Hello brave new world')
    assert big.length > small.length
  end

  test "produces identical output for repeated runs over the same template" do
    first = transform('Hello brave new world')
    10.times { assert_equal first, transform('Hello brave new world') }
    assert_equal first, I18n::PseudoLocale::Transformer.new.transform('Hello brave new world')
  end

  test "preserves named interpolation placeholders" do
    assert_equal '⟦Ħïê %{name}⟧', transform('Hi %{name}')
    assert_includes transform('%{greeting|hello} there'), '%{greeting|hello}'
  end

  test "preserves sprintf style placeholders" do
    assert_includes transform('You have %<count>d messages'), '%<count>d'
    assert_includes transform('Total %<price>.2f'), '%<price>.2f'
  end

  test "preserves escaped percents" do
    assert_includes transform('100%% sure'), '%%'
  end

  test "preserves HTML tag structure and link targets" do
    result = transform(%{Click <a href="https://example.com/orders/123" class="btn">here</a>})
    assert_includes result, '<a href="https://example.com/orders/123" class="btn">'
    assert_includes result, '</a>'
  end

  test "preserves HTML entities" do
    result = transform('Fish &amp; Chips &#169; &#xA9;')
    assert_includes result, '&amp;'
    assert_includes result, '&#169;'
    assert_includes result, '&#xA9;'
  end

  test "does not rewrite bare URLs" do
    result = transform('Visit https://example.com/path?q=1 today')
    assert_includes result, 'https://example.com/path?q=1'
  end

  test "does not rewrite email addresses" do
    result = transform('Mail support@example.com please')
    assert_includes result, 'support@example.com'
  end

  test "does not rewrite business IDs" do
    result = transform('Order ORD-12345 confirmed')
    assert_includes result, 'ORD-12345'
    uuid = '550e8400-e29b-41d4-a716-446655440000'
    assert_includes transform("Payment #{uuid} ok"), uuid
  end

  test "honors user-configured protected patterns" do
    I18n::PseudoLocale.configure do |config|
      config.protected_patterns << /INV\d+/
    end
    assert_includes transform('Invoice INV9981 sent'), 'INV9981'
  end

  test "keeps unsupported format fragments verbatim and records a queryable hint" do
    result = transform('Hello %s, you have %d credits (%.2f)')
    assert_includes result, '%s'
    assert_includes result, '%d'
    assert_includes result, '%.2f'

    fragments = I18n::PseudoLocale.hints.map(&:fragment)
    assert_includes fragments, '%s'
    assert_includes fragments, '%d'
    assert_includes fragments, '%.2f'
    hint = I18n::PseudoLocale.hints.first
    assert_equal 'Hello %s, you have %d credits (%.2f)', hint.string
    assert_match(/unsupported/, hint.reason)
  end

  test "hints can be cleared" do
    transform('Hello %s')
    refute_empty I18n::PseudoLocale.hints
    I18n::PseudoLocale.clear_hints
    assert_empty I18n::PseudoLocale.hints
  end

  test "enabled_for? reflects configured locales" do
    assert I18n::PseudoLocale.enabled_for?(:ps)
    assert I18n::PseudoLocale.enabled_for?('ps')
    refute I18n::PseudoLocale.enabled_for?(:en)
    refute I18n::PseudoLocale.enabled_for?(nil)
  end

  test "returns empty strings untouched" do
    assert_equal '', transform('')
  end
end
