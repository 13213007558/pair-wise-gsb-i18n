# encoding: utf-8

require 'test_helper'
require 'fileutils'

class I18nGettextBackendTest < I18n::TestCase
  include I18n::Gettext::Helpers

  class Backend < I18n::Backend::Simple
    include I18n::Backend::Gettext
  end

  class PluralizedBackend < I18n::Backend::Simple
    include I18n::Backend::Pluralization
    include I18n::Backend::Gettext
  end

  def setup
    super
    I18n.backend = Backend.new
    I18n.locale = :en
    I18n.load_path = ["#{locales_dir}/de.po"]
    I18n.default_separator = '|'
  end

  def teardown
    I18n::Gettext.plural_forms_conflict = :raise
    FileUtils.rm_rf(tmp_po_dir)
    super
  end

  def test_backend_loads_po_file
    I18n.backend.send(:init_translations)
    assert I18n.backend.send(:translations)[:de][:"Axis"]
  end

  def test_looks_up_a_translation
    I18n.locale = :de
    assert_equal 'Auto', gettext('car')
  end

  def test_uses_default_translation
    assert_equal 'car', gettext('car')
  end

  def test_looks_up_a_namespaced_translation
    I18n.locale = :de
    assert_equal 'Räderzahl', sgettext('Car|Wheels count')
    assert_equal 'Räderzahl', pgettext('Car', 'Wheels count')
    assert_equal 'Räderzahl!', pgettext('New car', 'Wheels count')
  end

  def test_uses_namespaced_default_translation
    assert_equal 'Wheels count', sgettext('Car|Wheels count')
    assert_equal 'Wheels count', pgettext('Car', 'Wheels count')
    assert_equal 'Wheels count', pgettext('New car', 'Wheels count')
  end

  def test_pluralizes_entry
    I18n.locale = :de
    assert_equal 'Achse', ngettext('Axis', 'Axis', 1)
    assert_equal 'Achsen', ngettext('Axis', 'Axis', 2)
  end

  def test_pluralizes_default_entry
    assert_equal 'Axis', ngettext('Axis', 'Axis', 1)
    assert_equal 'Axis', ngettext('Axis', 'Axis', 2)
  end

  def test_pluralizes_namespaced_entry
    I18n.locale = :de
    assert_equal 'Rad',   nsgettext('Car|wheel', 'wheels', 1)
    assert_equal 'Räder', nsgettext('Car|wheel', 'wheels', 2)
    assert_equal 'Rad',   npgettext('Car', 'wheel', 'wheels', 1)
    assert_equal 'Räder', npgettext('Car', 'wheel', 'wheels', 2)
    assert_equal 'Rad!', npgettext('New car', 'wheel', 'wheels', 1)
    assert_equal 'Räder!', npgettext('New car', 'wheel', 'wheels', 2)
  end

  def test_pluralizes_namespaced_default_entry
    assert_equal 'wheel',  nsgettext('Car|wheel', 'wheels', 1)
    assert_equal 'wheels', nsgettext('Car|wheel', 'wheels', 2)
    assert_equal 'wheel',  npgettext('Car', 'wheel', 'wheels', 1)
    assert_equal 'wheels', npgettext('Car', 'wheel', 'wheels', 2)
    assert_equal 'wheel', npgettext('New car', 'wheel', 'wheels', 1)
    assert_equal 'wheels', npgettext('New car', 'wheel', 'wheels', 2)
  end

  def test_pluralizes_namespaced_entry_with_alternative_syntax
    I18n.locale = :de
    assert_equal 'Rad',   nsgettext(['Car|wheel', 'wheels'], 1)
    assert_equal 'Räder', nsgettext(['Car|wheel', 'wheels'], 2)
    assert_equal 'Rad',   npgettext('Car', ['wheel', 'wheels'], 1)
    assert_equal 'Räder', npgettext('Car', ['wheel', 'wheels'], 2)
    assert_equal 'Rad!', npgettext('New car', ['wheel', 'wheels'], 1)
    assert_equal 'Räder!', npgettext('New car', ['wheel', 'wheels'], 2)
  end

  def test_ngettextpluralizes_entry_with_dots
    I18n.locale = :de
    assert_equal 'Auf 1 Achse.', n_("On %{count} wheel.", "On %{count} wheels.", 1)
    assert_equal 'Auf 2 Achsen.', n_("On %{count} wheel.", "On %{count} wheels.", 2)
  end

  def test_uses_plural_form_index_declared_by_po_file
    I18n.load_path = ["#{locales_dir}/ru.po"]
    I18n.locale = :ru

    assert_equal 'много яблок', ngettext('apple', 'apples', 0)
    assert_equal 'одно яблоко', ngettext('apple', 'apples', 1)
    assert_equal 'несколько яблок', ngettext('apple', 'apples', 2)
    assert_equal 'много яблок', ngettext('apple', 'apples', 11)
    assert_equal 'одно яблоко', ngettext('apple', 'apples', 21)
  end

  def test_declared_plural_form_works_when_pluralization_backend_is_included_first
    I18n.backend = PluralizedBackend.new
    I18n.load_path = ["#{locales_dir}/ru.po"]
    I18n.locale = :ru

    assert_equal 'несколько яблок', ngettext('apple', 'apples', 2)
    assert_equal 'много яблок', ngettext('apple', 'apples', 11)
  end

  def test_rejects_invalid_plural_expression_with_file_location
    write_po_file('invalid/ru.po', plural_expression: 'n +', nplurals: 2)
    I18n.load_path = [po_path('invalid/ru.po')]

    error = assert_raises(I18n::Gettext::PluralForm::Error) do
      I18n.backend.send(:init_translations)
    end
    assert_match(/#{Regexp.escape(po_path('invalid/ru.po'))}/, error.message)
    assert_match(/unexpected token/, error.message)
    assert_match(/position 3/, error.message)
  end

  def test_rejects_entries_when_translation_count_differs_from_nplurals
    write_po_file('wrong-count/ru.po', nplurals: 3, translations: ['zero', 'one'])
    I18n.load_path = [po_path('wrong-count/ru.po')]

    error = assert_raises(I18n::Gettext::PluralForm::Error) do
      I18n.backend.send(:init_translations)
    end
    assert_match(/#{Regexp.escape(po_path('wrong-count/ru.po'))}/, error.message)
    assert_match(/expected 3, got 2/, error.message)
    assert_match(/msgid "apple"/, error.message)
  end

  def test_rejects_runtime_index_outside_declared_nplurals
    write_po_file('out-of-range/ru.po', plural_expression: 'n', nplurals: 2)
    I18n.load_path = [po_path('out-of-range/ru.po')]
    I18n.locale = :ru

    error = assert_raises(I18n::Gettext::PluralForm::ResultOutOfRange) do
      ngettext('apple', 'apples', 2)
    end
    assert_match(/#{Regexp.escape(po_path('out-of-range/ru.po'))}/, error.message)
    assert_match(/returned 2/, error.message)
  end

  def test_rejects_runtime_division_by_zero_with_expression_position
    write_po_file('zero-division/ru.po', plural_expression: 'n / 0', nplurals: 2)
    I18n.load_path = [po_path('zero-division/ru.po')]
    I18n.locale = :ru

    error = assert_raises(I18n::Gettext::PluralForm::EvaluationError) do
      ngettext('apple', 'apples', 1)
    end
    assert_match(/#{Regexp.escape(po_path('zero-division/ru.po'))}/, error.message)
    assert_match(/division by zero/, error.message)
    assert_match(/at position 2/, error.message)
  end

  def test_rejects_conflicting_plural_forms_for_same_locale_by_default
    write_conflicting_po_files
    I18n.load_path = [po_path('first/ru.po'), po_path('last/ru.po')]

    error = assert_raises(I18n::Gettext::PluralForm::Error) do
      I18n.backend.send(:init_translations)
    end
    assert_match(/conflicting Plural-Forms for :ru/, error.message)
    assert_match(/first/, error.message)
    assert_match(/last/, error.message)
  end

  def test_uses_first_plural_form_when_conflict_strategy_is_first
    I18n::Gettext.plural_forms_conflict = :first
    write_conflicting_po_files
    I18n.load_path = [po_path('first/ru.po'), po_path('last/ru.po')]
    I18n.locale = :ru

    assert_equal 'last-index-2', ngettext('apple', 'apples', 11)
  end

  def test_uses_last_plural_form_when_conflict_strategy_is_last
    I18n::Gettext.plural_forms_conflict = :last
    write_conflicting_po_files
    I18n.load_path = [po_path('first/ru.po'), po_path('last/ru.po')]
    I18n.locale = :ru

    assert_equal 'last-index-1', ngettext('apple', 'apples', 11)
  end

  def test_rejects_conflicting_nplurals_even_when_last_strategy_is_configured
    I18n::Gettext.plural_forms_conflict = :last
    write_po_file(
      'first/ru.po',
      plural_expression: 'n != 1',
      nplurals: 2,
      translations: ['first-index-0', 'first-index-1']
    )
    write_po_file(
      'last/ru.po',
      plural_expression: 'n == 1 ? 0 : 1',
      nplurals: 3,
      translations: ['last-index-0', 'last-index-1', 'last-index-2']
    )
    I18n.load_path = [po_path('first/ru.po'), po_path('last/ru.po')]

    error = assert_raises(I18n::Gettext::PluralForm::Error) do
      I18n.backend.send(:init_translations)
    end
    assert_match(/conflicting Plural-Forms nplurals for :ru/, error.message)
  end

  private

  def tmp_po_dir
    File.expand_path('../../.tmp/gettext-backend-tests', __dir__)
  end

  def po_path(relative_path)
    File.join(tmp_po_dir, relative_path)
  end

  def write_po_file(relative_path, plural_expression: 'n != 1', nplurals: 2, translations: nil)
    translations ||= Array.new(nplurals) { |index| "translation-#{index}" }
    msgstrs = translations.each_with_index.map do |translation, index|
      %Q{msgstr[#{index}] "#{translation}"}
    end.join("\n")

    write_file(relative_path, <<~PO)
      msgid ""
      msgstr ""
      "Plural-Forms: nplurals=#{nplurals}; plural=#{plural_expression};\\n"

      msgid "apple"
      msgid_plural "apples"
      #{msgstrs}
    PO
  end

  def write_conflicting_po_files
    write_po_file(
      'first/ru.po',
      plural_expression: 'n == 1 ? 0 : n == 2 ? 1 : 2',
      nplurals: 3,
      translations: ['first-index-0', 'first-index-1', 'first-index-2']
    )
    write_po_file(
      'last/ru.po',
      plural_expression: 'n == 1 ? 0 : 1',
      nplurals: 3,
      translations: ['last-index-0', 'last-index-1', 'last-index-2']
    )
  end

  def write_file(relative_path, contents)
    path = po_path(relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end
end
