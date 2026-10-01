# encoding: utf-8

require 'test_helper'
require 'tmpdir'

class I18nGettextBackendPluralFormsTest < I18n::TestCase
  include I18n::Gettext::Helpers

  class Backend < I18n::Backend::Simple
    include I18n::Backend::Gettext
  end

  def setup
    super
    I18n.backend = Backend.new
    I18n.default_separator = '|'
    @previous_conflict_strategy = I18n::Gettext.plural_forms_conflict_strategy
  end

  def teardown
    I18n::Gettext.plural_forms_conflict_strategy = @previous_conflict_strategy
    super
  end

  test "picks msgstr indices using the Plural-Forms rule declared by the PO file" do
    I18n.load_path = ["#{locales_dir}/ru.po"]
    I18n.locale = :ru

    # nplurals=3; plural=n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2;
    assert_equal '0 осей',  ngettext('Axis', 'Axes', 0)
    assert_equal '1 ось',   ngettext('Axis', 'Axes', 1)
    assert_equal '2 оси',   ngettext('Axis', 'Axes', 2)
    assert_equal '4 оси',   ngettext('Axis', 'Axes', 4)
    assert_equal '5 осей',  ngettext('Axis', 'Axes', 5)
    assert_equal '11 осей', ngettext('Axis', 'Axes', 11)
    assert_equal '21 ось',  ngettext('Axis', 'Axes', 21)
    assert_equal '22 оси',  ngettext('Axis', 'Axes', 22)
    assert_equal '111 осей', ngettext('Axis', 'Axes', 111)
  end

  test "uses the Plural-Forms rule of de.po instead of the preset plural keys" do
    I18n.load_path = ["#{locales_dir}/de.po"]
    I18n.locale = :de

    assert_equal 'Achse',  ngettext('Axis', 'Axis', 1)
    assert_equal 'Achsen', ngettext('Axis', 'Axis', 2)
    assert_equal 'Achsen', ngettext('Axis', 'Axis', 0)
  end

  test "falls back to preset plural keys when the PO file declares no Plural-Forms" do
    with_po_files(po_string(:entries => <<~PO)) do
      msgid "wheel"
      msgid_plural "wheels"
      msgstr[0] "one wheel"
      msgstr[1] "many wheels"
    PO
      I18n.locale = :zz
      assert_equal 'one wheel',   ngettext('wheel', 'wheels', 1)
      assert_equal 'many wheels', ngettext('wheel', 'wheels', 2)
    end
  end

  test "raises ConflictingRules when two files for one locale declare different rules" do
    two_form = po_string(:plural_forms => 'nplurals=2; plural=(n != 1);')
    three_form = po_string(:plural_forms => 'nplurals=3; plural=n==1 ? 0 : n==2 ? 1 : 2;')

    error = assert_raises(I18n::Gettext::PluralForms::ConflictingRules) do
      with_po_files(two_form, three_form) { load_translations }
    end
    assert_match(/conflicting Plural-Forms rules for locale zz/, error.message)
    assert_match(/zz\.po/, error.message)
  end

  test "accepts identical Plural-Forms rules declared by multiple files" do
    rule = 'nplurals=2; plural=(n != 1);'
    entries = <<~PO
      msgid "wheel"
      msgid_plural "wheels"
      msgstr[0] "one wheel"
      msgstr[1] "many wheels"
    PO

    with_po_files(po_string(:plural_forms => rule), po_string(:plural_forms => rule, :entries => entries)) do
      load_translations
      I18n.locale = :zz
      assert_equal 'many wheels', ngettext('wheel', 'wheels', 2)
    end
  end

  test "keeps the first rule when the conflict strategy is :first" do
    I18n::Gettext.plural_forms_conflict_strategy = :first
    entries = <<~PO
      msgid "wheel"
      msgid_plural "wheels"
      msgstr[0] "index zero"
      msgstr[1] "index one"
    PO

    with_po_files(
      po_string(:plural_forms => 'nplurals=2; plural=(n != 1);', :entries => entries),
      po_string(:plural_forms => 'nplurals=2; plural=(n == 1);')
    ) do
      load_translations
      I18n.locale = :zz
      assert_equal 'index zero', ngettext('wheel', 'wheels', 1)
      assert_equal 'index one',  ngettext('wheel', 'wheels', 0)
    end
  end

  test "uses the last rule when the conflict strategy is :last" do
    I18n::Gettext.plural_forms_conflict_strategy = :last
    entries = <<~PO
      msgid "wheel"
      msgid_plural "wheels"
      msgstr[0] "index zero"
      msgstr[1] "index one"
    PO

    with_po_files(
      po_string(:plural_forms => 'nplurals=2; plural=(n != 1);'),
      po_string(:plural_forms => 'nplurals=2; plural=(n == 1);', :entries => entries)
    ) do
      load_translations
      I18n.locale = :zz
      assert_equal 'index one',  ngettext('wheel', 'wheels', 1)
      assert_equal 'index zero', ngettext('wheel', 'wheels', 0)
    end
  end

  test "rejects an unknown conflict strategy" do
    assert_raises(ArgumentError) { I18n::Gettext.plural_forms_conflict_strategy = :bogus }
  end

  test "raises PluralCountMismatch when msgstr count does not match nplurals" do
    file = po_string(
      :plural_forms => 'nplurals=3; plural=n==1 ? 0 : n==2 ? 1 : 2;',
      :entries => <<~PO
        msgid "wheel"
        msgid_plural "wheels"
        msgstr[0] "one wheel"
        msgstr[1] "many wheels"
      PO
    )

    error = assert_raises(I18n::Gettext::PluralForms::PluralCountMismatch) do
      with_po_files(file) { load_translations }
    end
    assert_match(/zz\.po/, error.message)
    assert_match(/"wheel"/, error.message)
    assert_match(/nplurals=3/, error.message)
  end

  test "raises a SyntaxError locating the file for an invalid plural expression" do
    file = po_string(:plural_forms => 'nplurals=2; plural=(n != ;')

    error = assert_raises(I18n::Gettext::PluralForms::SyntaxError) do
      with_po_files(file) { load_translations }
    end
    assert_match(/zz\.po/, error.message)
    assert_match(/syntax error/, error.message)
  end

  test "raises DivisionByZero with location when the rule divides by zero at runtime" do
    file = po_string(
      :plural_forms => 'nplurals=2; plural=n/(n-n) ? 0 : 1;',
      :entries => <<~PO
        msgid "wheel"
        msgid_plural "wheels"
        msgstr[0] "one wheel"
        msgstr[1] "many wheels"
      PO
    )

    with_po_files(file) do
      I18n.locale = :zz
      error = assert_raises(I18n::Gettext::PluralForms::DivisionByZero) do
        ngettext('wheel', 'wheels', 2)
      end
      assert_match(/zz\.po/, error.message)
      assert_match(/n=2/, error.message)
    end
  end

  test "raises InvalidIndex with location when the rule result is out of range" do
    file = po_string(
      :plural_forms => 'nplurals=2; plural=n;',
      :entries => <<~PO
        msgid "wheel"
        msgid_plural "wheels"
        msgstr[0] "one wheel"
        msgstr[1] "many wheels"
      PO
    )

    with_po_files(file) do
      I18n.locale = :zz
      error = assert_raises(I18n::Gettext::PluralForms::InvalidIndex) do
        ngettext('wheel', 'wheels', 5)
      end
      assert_match(/zz\.po/, error.message)
      assert_match(/n=5/, error.message)
    end
  end

  test "forgets Plural-Forms rules on reload" do
    I18n.load_path = ["#{locales_dir}/ru.po"]
    I18n.backend.send(:init_translations)
    assert I18n.backend.send(:gettext_plural_forms)[:ru]

    I18n.backend.reload!
    assert_empty I18n.backend.send(:gettext_plural_forms)
  end

  protected

  def load_translations
    I18n.backend.send(:init_translations)
  end

  def po_string(plural_forms: nil, entries: '')
    header = +"msgid \"\"\nmsgstr \"\"\n\"Content-Type: text/plain; charset=UTF-8\\n\"\n"
    header << "\"Plural-Forms: #{plural_forms}\\n\"\n" if plural_forms
    header << "\n" << entries
  end

  # Writes each given PO file content to a zz.po file in its own directory
  # (so they all map to the :zz locale) and adds them to the load path.
  def with_po_files(*contents)
    Dir.mktmpdir do |dir|
      contents.each_with_index do |content, index|
        subdir = File.join(dir, index.to_s)
        Dir.mkdir(subdir)
        I18n.load_path += [File.join(subdir, 'zz.po')].tap do |path|
          File.write(path.first, content)
        end
      end
      yield
    end
  end
end

