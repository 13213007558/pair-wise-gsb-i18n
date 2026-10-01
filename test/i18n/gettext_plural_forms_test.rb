# encoding: utf-8

require 'test_helper'

class I18nGettextPluralFormsTest < I18n::TestCase
  PluralForms = I18n::Gettext::PluralForms

  test "parses nplurals and the plural expression from a header" do
    forms = PluralForms.parse('nplurals=2; plural=(n != 1);')
    assert_equal 2, forms.nplurals
    assert_equal '(n != 1)', forms.expression
  end

  test "raises a SyntaxError with location when nplurals is missing" do
    error = assert_raises(PluralForms::SyntaxError) do
      PluralForms.parse('plural=n;', 'locales/zz.po')
    end
    assert_match(/locales\/zz\.po/, error.message)
    assert_match(/nplurals/, error.message)
  end

  test "raises a SyntaxError with location when plural is missing" do
    error = assert_raises(PluralForms::SyntaxError) do
      PluralForms.parse('nplurals=2;', 'locales/zz.po')
    end
    assert_match(/locales\/zz\.po/, error.message)
    assert_match(/plural/, error.message)
  end

  test "raises a SyntaxError when nplurals is zero" do
    assert_raises(PluralForms::SyntaxError) { PluralForms.new(0, 'n') }
  end

  test "evaluates integer arithmetic with C operator precedence" do
    assert_equal 1, PluralForms.new(2, '2 + 3 * 4 == 14 ? 1 : 0').call(0)
    assert_equal 1, PluralForms.new(2, '(2 + 3) * 4 == 20 ? 1 : 0').call(0)
    assert_equal 1, PluralForms.new(2, '7 % 3 == 1 ? 1 : 0').call(0)
    assert_equal 1, PluralForms.new(2, '1 << 3 == 8 ? 1 : 0').call(0)
    assert_equal 1, PluralForms.new(2, '8 >> 2 == 2 ? 1 : 0').call(0)
  end

  test "evaluates comparisons to 1 or 0 like C" do
    assert_equal 1, PluralForms.new(2, 'n > 1').call(2)
    assert_equal 0, PluralForms.new(2, 'n > 1').call(1)
    assert_equal 1, PluralForms.new(2, 'n <= 1').call(0)
    assert_equal 1, PluralForms.new(2, 'n == 3').call(3)
    assert_equal 1, PluralForms.new(2, 'n != 3').call(4)
  end

  test "evaluates unary operators" do
    assert_equal 1, PluralForms.new(2, '!n').call(0)
    assert_equal 0, PluralForms.new(2, '!n').call(5)
    assert_equal 1, PluralForms.new(2, '-n == -3 ? 1 : 0').call(3)
    assert_equal 1, PluralForms.new(2, '~0 == -1 ? 1 : 0').call(0)
    assert_equal 1, PluralForms.new(2, '+n == 7 ? 1 : 0').call(7)
  end

  test "evaluates nested ternary expressions" do
    forms = PluralForms.new(3, 'n == 1 ? 0 : n == 2 ? 1 : 2')
    assert_equal 0, forms.call(1)
    assert_equal 1, forms.call(2)
    assert_equal 2, forms.call(3)
  end

  test "short-circuits && and ||" do
    forms = PluralForms.new(2, 'n != 0 && 10 / n > 1 ? 1 : 0')
    assert_equal 0, forms.call(0)
    assert_equal 1, forms.call(5)

    forms = PluralForms.new(2, 'n == 0 || 10 / n > 1 ? 1 : 0')
    assert_equal 1, forms.call(0)
  end

  test "only evaluates the selected ternary branch" do
    forms = PluralForms.new(2, 'n == 0 ? 0 : 10 / n > 100 ? 1 : 0')
    assert_equal 0, forms.call(0)
  end

  test "divides and truncates towards zero like C" do
    assert_equal 1, PluralForms.new(3, '(-7 / 2) + 4').call(0)  # -3 + 4
    assert_equal 2, PluralForms.new(3, '(-7 % 3) + 3').call(0)  # -1 + 3
    assert_equal 1, PluralForms.new(2, '7 / 2 == 3 ? 1 : 0').call(0)
  end

  test "raises DivisionByZero with expression, count and location" do
    forms = PluralForms.new(2, 'n / (n - n)', 'locales/zz.po')
    error = assert_raises(PluralForms::DivisionByZero) { forms.call(3) }
    assert_match(/locales\/zz\.po/, error.message)
    assert_match(/division by zero/, error.message)
    assert_match(/n=3/, error.message)

    assert_raises(PluralForms::DivisionByZero) { PluralForms.new(2, 'n % 0').call(1) }
  end

  test "raises InvalidIndex when the result is out of range" do
    forms = PluralForms.new(2, 'n', 'locales/zz.po')
    error = assert_raises(PluralForms::InvalidIndex) { forms.call(5) }
    assert_match(/locales\/zz\.po/, error.message)
    assert_match(/n=5/, error.message)
    assert_match(/nplurals is 2/, error.message)

    assert_raises(PluralForms::InvalidIndex) { PluralForms.new(2, '-1').call(0) }
  end

  test "raises a SyntaxError with position for unexpected tokens" do
    error = assert_raises(PluralForms::SyntaxError) { PluralForms.new(2, 'n + * 2', 'zz.po') }
    assert_match(/zz\.po/, error.message)
    assert_match(/position 4/, error.message)

    error = assert_raises(PluralForms::SyntaxError) { PluralForms.new(2, 'n ? 1', 'zz.po') }
    assert_match(/expected ":"/, error.message)

    error = assert_raises(PluralForms::SyntaxError) { PluralForms.new(2, 'n n', 'zz.po') }
    assert_match(/unexpected "n"/, error.message)

    error = assert_raises(PluralForms::SyntaxError) { PluralForms.new(2, 'exit(1)', 'zz.po') }
    assert_match(/unexpected character/, error.message)

    assert_raises(PluralForms::SyntaxError) { PluralForms.new(2, '(n', 'zz.po') }
    assert_raises(PluralForms::SyntaxError) { PluralForms.new(2, '', 'zz.po') }
  end

  test "does not evaluate Ruby code" do
    assert_raises(PluralForms::SyntaxError) { PluralForms.new(2, 'system("echo pwned")') }
    assert_raises(PluralForms::SyntaxError) { PluralForms.new(2, '%x(echo pwned)') }
    assert_raises(PluralForms::SyntaxError) { PluralForms.new(2, 'n.send(:exit)') }
  end

  test "raises an EvaluationError for non-integer counts" do
    forms = PluralForms.new(2, 'n != 1')
    assert_raises(PluralForms::EvaluationError) { forms.call('foo') }
    assert_raises(PluralForms::EvaluationError) { forms.call(nil) }
  end

  test "equality ignores whitespace but not semantics" do
    assert_equal PluralForms.parse('nplurals=2; plural=(n != 1);'),
                 PluralForms.parse('nplurals=2; plural=(n!=1);')
    refute_equal PluralForms.parse('nplurals=2; plural=(n != 1);'),
                 PluralForms.parse('nplurals=2; plural=(n != 2);')
    refute_equal PluralForms.parse('nplurals=2; plural=(n != 1);'),
                 PluralForms.parse('nplurals=3; plural=(n != 1);')
  end

  test "selects the expected index for a three-form (Russian style) rule" do
    forms = PluralForms.parse(
      'nplurals=3; plural=n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2;'
    )
    expectations = {
      0 => 2, 1 => 0, 2 => 1, 3 => 1, 4 => 1, 5 => 2,
      11 => 2, 12 => 2, 14 => 2,
      21 => 0, 22 => 1, 25 => 2,
      101 => 0, 111 => 2, 121 => 0
    }
    expectations.each do |n, index|
      assert_equal index, forms.call(n), "expected index #{index} for n=#{n}"
    end
  end

  test "supports single-form rules" do
    forms = PluralForms.parse('nplurals=1; plural=0;')
    assert_equal 0, forms.call(0)
    assert_equal 0, forms.call(100)
  end
end

