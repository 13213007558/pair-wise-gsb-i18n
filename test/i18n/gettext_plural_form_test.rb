# frozen_string_literal: true

require 'test_helper'

class I18nGettextPluralFormTest < I18n::TestCase
  def teardown
    I18n::Gettext.plural_forms_conflict = :raise
    super
  end

  def form(expression = 'n != 1', nplurals = 2, filename: 'ru.po')
    I18n::Gettext::PluralForm.parse(
      "nplurals=#{nplurals}; plural=#{expression};",
      filename: filename
    )
  end

  test 'evaluates integer arithmetic with C-style truncated division' do
    plural_form = form('n / 10 + n % 10', 4)
    assert_equal 3, plural_form.call(12)
    assert_equal(-2, form('n / 5').send(:evaluate, -12))
  end

  test 'evaluates comparisons as integer values' do
    plural_form = form('n >= 2 && n <= 4')
    assert_equal 1, plural_form.call(3)
    assert_equal 0, plural_form.call(11)
  end

  test 'supports logical short circuiting to avoid division by zero' do
    plural_form = form('n == 0 ? 1 : n / n')
    assert_equal 1, plural_form.call(0)
    assert_equal 1, plural_form.call(7)
  end

  test 'supports nested ternary conditions' do
    plural_form = form('n == 1 ? 0 : n == 2 ? 1 : 2', 3)
    assert_equal [0, 1, 2], [1, 2, 11].map { |count| plural_form.call(count) }
  end

  test 'rejects syntax errors with location information' do
    error = assert_raises(I18n::Gettext::PluralForm::ParseError) do
      form('n +')
    end

    assert_equal 'n +', error.source
    assert_equal 3, error.position
    assert_match(/position 3/, error.message)
  end

  test 'reports division and modulo by zero' do
    plural_form = form('n / 0')
    error = assert_raises(I18n::Gettext::PluralForm::EvaluationError) { plural_form.call(1) }
    assert_match(/division by zero/, error.message)
    assert_match(/at position 2/, error.message)
    assert_match(/ru\.po/, error.message)
  end

  test 'reports out of range results with location information' do
    plural_form = form('n', 2)
    error = assert_raises(I18n::Gettext::PluralForm::ResultOutOfRange) { plural_form.call(2) }
    assert_match(/returned 2/, error.message)
    assert_match(/expected an integer in 0\.\.\.2/, error.message)
    assert_match(/ru\.po/, error.message)
  end

  test 'does not evaluate arbitrary Ruby expressions' do
    assert_raises(I18n::Gettext::PluralForm::ParseError) do
      form('system("true")')
    end
  end

  test 'equivalent expressions with different whitespace use the same rule' do
    first = form('n != 1')
    second = I18n::Gettext::PluralForm.parse('nplurals=2;plural=n!=1;')

    assert_equal first, second
  end

  test 'rejects unknown plural form conflict strategies' do
    error = assert_raises(ArgumentError) do
      I18n::Gettext.plural_forms_conflict = :replace
    end

    assert_match(/unknown Plural-Forms conflict strategy :replace/, error.message)
  end
end
