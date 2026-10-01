# encoding: utf-8
require 'test_helper'

class I18nBackendTransliterator < I18n::TestCase
  def setup
    super
    I18n.backend = I18n::Backend::Simple.new
    @proc = lambda { |n| n.upcase }
    @hash = { "ü" => "ue", "ö" => "oe", "a" => "a" }
    @transliterator = I18n::Backend::Transliterator.get
  end

  test "transliteration rule can be a proc" do
    store_translations(:xx, :i18n => {:transliterate => {:rule => @proc}})
    assert_equal "HELLO", I18n.backend.transliterate(:xx, "hello")
  end

  test "transliteration rule can be a hash" do
    store_translations(:xx, :i18n => {:transliterate => {:rule => @hash}})
    assert_equal "ue", I18n.backend.transliterate(:xx, "ü")
  end

  test "transliteration rule must be a proc or hash" do
    store_translations(:xx, :i18n => {:transliterate => {:rule => ""}})
    assert_raises I18n::ArgumentError do
      I18n.backend.transliterate(:xx, "ü")
    end
  end

  test "transliterator defaults to latin => ascii when no rule is given" do
    assert_equal "AEroskobing", I18n.backend.transliterate(:xx, "Ærøskøbing")
  end

  test "default transliterator should not modify ascii characters" do
    (0..127).each do |byte|
      char = [byte].pack("U")
      assert_equal char, @transliterator.transliterate(char)
    end
  end

  test "default transliterator correctly transliterates latin characters" do
    # create string with range of Unicode's western characters with
    # diacritics, excluding the division and multiplication signs which for
    # some reason or other are floating in the middle of all the letters.
    string = (0xC0..0x17E).to_a.reject {|c| [0xD7, 0xF7].include? c}.append(0x1E9E).pack("U*")
    string.split(//) do |char|
      assert_match %r{^[a-zA-Z']*$}, @transliterator.transliterate(string)
    end
  end

  test "should replace non-ASCII chars not in map with a replacement char" do
    assert_equal "abc?", @transliterator.transliterate("abcſ")
  end

  test "can replace non-ASCII chars not in map with a custom replacement string" do
    assert_equal "abc#", @transliterator.transliterate("abcſ", "#")
  end

  test "can keep non-ASCII chars not in map with :none" do
    assert_equal "abcſ", @transliterator.transliterate("abcſ", :none)
  end

  test "default transliterator raises errors for invalid UTF-8" do
    assert_raises ArgumentError do
      @transliterator.transliterate("a\x92b")
    end
  end

  test "I18n.transliterate should transliterate using a default transliterator" do
    assert_equal "aeo", I18n.transliterate("áèö")
  end

  test "I18n.transliterate should transliterate using a locale" do
    store_translations(:xx, :i18n => {:transliterate => {:rule => @hash}})
    assert_equal "ue", I18n.transliterate("ü", :locale => :xx)
  end

  test "default transliterator fails with custom rules with uncomposed input" do
    char = [117, 776].pack("U*") # "ü" as ASCII "u" plus COMBINING DIAERESIS
    transliterator = I18n::Backend::Transliterator.get(@hash)
    refute_equal "ue", transliterator.transliterate(char)
  end

  test "DEFAULT_APPROXIMATIONS is frozen to prevent concurrency issues" do
    assert I18n::Backend::Transliterator::HashTransliterator::DEFAULT_APPROXIMATIONS.frozen?
  end

  # --- Declarative rules ------------------------------------------------

  Rule = I18n::Backend::Transliterator::Rule

  test "declarative transliterator can be built from a single rule" do
    transliterator = I18n::Backend::Transliterator.get(Rule.new(:from => "ü", :to => "ue"))
    assert_equal "ue", transliterator.transliterate("ü")
  end

  test "declarative transliterator can be built from an array of rules" do
    rules = [
      Rule.new(:from => "ü", :to => "ue"),
      Rule.new(:from => "ö", :to => "oe")
    ]
    transliterator = I18n::Backend::Transliterator.get(rules)
    assert_equal "ueoe", transliterator.transliterate("üö")
  end

  test "declarative rules support multi-character input" do
    rules = [
      Rule.new(:from => "ch", :to => "k", :match_ascii => true),
      Rule.new(:from => "sch", :to => "sh", :match_ascii => true)
    ]
    transliterator = I18n::Backend::Transliterator.get(rules)
    assert_equal "sh", transliterator.transliterate("sch")
    assert_equal "sak", transliterator.transliterate("sach")
  end

  test "rules use the longest valid match" do
    rules = [
      Rule.new(:from => "ch", :to => "X", :match_ascii => true),
      Rule.new(:from => "chsch", :to => "LONG", :match_ascii => true),
      Rule.new(:from => "sch", :to => "Y", :match_ascii => true)
    ]
    transliterator = I18n::Backend::Transliterator.get(rules)
    assert_equal "LONG", transliterator.transliterate("chsch")
    assert_equal "pLONGq", transliterator.transliterate("pchschq")
  end

  test "rules of equal length are resolved by priority" do
    rules = [
      Rule.new(:from => "ae", :to => "low", :priority => -5, :match_ascii => true),
      Rule.new(:from => "ae", :to => "high", :priority => 5, :match_ascii => true)
    ]
    transliterator = I18n::Backend::Transliterator.get(rules)
    assert_equal "high", transliterator.transliterate("ae")
  end

  test "rules of equal length and priority are resolved in definition order" do
    rules = [
      Rule.new(:from => "ae", :to => "first", :match_ascii => true),
      Rule.new(:from => "ae", :to => "second", :match_ascii => true)
    ]
    transliterator = I18n::Backend::Transliterator.get(rules)
    assert_equal "first", transliterator.transliterate("ae")
  end

  test "declarative rules inherit default approximations" do
    transliterator = I18n::Backend::Transliterator.get(
      Rule.new(:from => "ü", :to => "ue")
    )
    assert_equal "ueAEroskobing", transliterator.transliterate("üÆrøskøbing")
  end

  test "declarative rules override default approximations" do
    transliterator = I18n::Backend::Transliterator.get(
      Rule.new(:from => "ü", :to => "yui", :priority => 10)
    )
    assert_equal "yui", transliterator.transliterate("ü")
  end

  test "a hash containing rule values builds a rule transliterator" do
    transliterator = I18n::Backend::Transliterator.get({
      "ü" => Rule.new(:from => "ü", :to => "yui")
    })
    assert_equal "yuix", transliterator.transliterate("üx")
  end

  test "plain ascii rules do not match unless match_ascii is set" do
    without_flag = I18n::Backend::Transliterator.get(
      Rule.new(:from => "ch", :to => "k")
    )
    assert_equal "ch", without_flag.transliterate("ch")

    with_flag = I18n::Backend::Transliterator.get(
      Rule.new(:from => "ch", :to => "k", :match_ascii => true)
    )
    assert_equal "k", with_flag.transliterate("ch")
  end

  test "string left context constrains a match" do
    rules = [
      Rule.new(:from => "ü", :to => "ue"),
      Rule.new(:from => "ü", :to => "u", :left => "q", :priority => 1)
    ]
    transliterator = I18n::Backend::Transliterator.get(rules)
    assert_equal "qux", transliterator.transliterate("qux")
    assert_equal "muel", transliterator.transliterate("mül")
  end

  test "string right context constrains a match" do
    rules = [
      Rule.new(:from => "ü", :to => "ue"),
      Rule.new(:from => "ü", :to => "u", :right => "n", :priority => 1)
    ]
    transliterator = I18n::Backend::Transliterator.get(rules)
    assert_equal "kun", transliterator.transliterate("kün")
    assert_equal "kuem", transliterator.transliterate("küm")
  end

  test "regexp contexts support word boundaries" do
    rules = [
      Rule.new(:from => "ğ", :to => "B"),
      Rule.new(:from => "ğ", :to => "A", :right => /\b/, :priority => 1),
      Rule.new(:from => "ğ", :to => "C", :left => /\b/, :priority => 1)
    ]
    transliterator = I18n::Backend::Transliterator.get(rules)
    assert_equal "daA", transliterator.transliterate("dağ")
    assert_equal "Cda", transliterator.transliterate("ğda")
    assert_equal "daBda", transliterator.transliterate("dağda")
  end

  test "rules match decomposed input under NFC normalization" do
    decomposed = [117, 776].pack("U*") # "ü" as "u" + combining diaeresis
    transliterator = I18n::Backend::Transliterator.get(
      Rule.new(:from => "ü", :to => "ue")
    )
    assert_equal "ue", transliterator.transliterate(decomposed)
  end

  test "transliterate_with_ranges maps output back to original input" do
    transliterator = I18n::Backend::Transliterator.get([
      Rule.new(:from => "ch", :to => "k", :match_ascii => true),
      Rule.new(:from => "ü", :to => "ue")
    ])
    fragments = transliterator.transliterate_with_ranges("chüx")
    assert_equal [["k", (0...2)], ["ue", (2...3)], ["x", (3...4)]], fragments
  end

  test "ranges cover combining characters in the original input" do
    decomposed = [117, 776].pack("U*")
    transliterator = I18n::Backend::Transliterator.get(
      Rule.new(:from => "ü", :to => "ue")
    )
    fragments = transliterator.transliterate_with_ranges("a#{decomposed}z")
    assert_equal [["a", (0...1)], ["ue", (1...3)], ["z", (3...4)]], fragments
  end

  test "ranges can reconstruct the output through transliterate" do
    transliterator = I18n::Backend::Transliterator.get(
      Rule.new(:from => "ü", :to => "ue")
    )
    input = "hübsch"
    fragments = transliterator.transliterate_with_ranges(input)
    assert_equal transliterator.transliterate(input), fragments.map { |output, _| output }.join
  end

  test "unknown characters still honor the replacement option with rules" do
    transliterator = I18n::Backend::Transliterator.get(
      Rule.new(:from => "ü", :to => "ue")
    )
    assert_equal "ue?", transliterator.transliterate("üſ")
    assert_equal "ue#", transliterator.transliterate("üſ", "#")
    assert_equal "ueſ", transliterator.transliterate("üſ", :none)
  end

  test "transliterated output is not fed back into the rules" do
    # A rule on "ue" must never consume the "ue" emitted for "ü".
    transliterator = I18n::Backend::Transliterator.get([
      Rule.new(:from => "ü", :to => "ue"),
      Rule.new(:from => "ue", :to => "LOOP", :match_ascii => true)
    ])
    assert_equal "ue", transliterator.transliterate("ü")
  end

  test "rules with an empty replacement delete the match" do
    transliterator = I18n::Backend::Transliterator.get(
      Rule.new(:from => "ğ", :to => "")
    )
    assert_equal "ab", transliterator.transliterate("ağb")
  end

  test "the same input always produces the same result with overlapping rules" do
    rules = [
      Rule.new(:from => "ch", :to => "tch", :match_ascii => true),
      Rule.new(:from => "chsch", :to => "X", :match_ascii => true),
      Rule.new(:from => "sch", :to => "sh", :match_ascii => true),
      Rule.new(:from => "ß", :to => "ss"),
      Rule.new(:from => "ss", :to => "Y", :match_ascii => true, :priority => 2)
    ]
    transliterator = I18n::Backend::Transliterator.get(rules)
    input = "Großsch chsch sch chschiff ß ss"
    results = Array.new(50) { transliterator.transliterate(input) }
    assert_equal [results.first], results.uniq
  end

  test "combining characters, boundaries and overlap together stay deterministic" do
    decomposed = [117, 776].pack("U*")
    rules = [
      Rule.new(:from => "ü", :to => "ue"),
      Rule.new(:from => "ü", :to => "u", :left => /\b/, :priority => 1),
      Rule.new(:from => "üe", :to => "UE", :priority => 5)
    ]
    transliterator = I18n::Backend::Transliterator.get(rules)
    input = "#{decomposed}e müde #{decomposed}"
    results = Array.new(50) { transliterator.transliterate(input) }
    assert_equal [results.first], results.uniq
  end

  test "nfd normalization form matches decomposed multi-codepoint rules" do
    composed = "ü"
    transliterator = I18n::Backend::Transliterator.get(
      Rule.new(:from => [117, 776].pack("U*"), :to => "ue"),
      :normalization_form => :nfd
    )
    assert_equal "ue", transliterator.transliterate(composed)
  end

  test "nfkc expands compatibility characters with accurate source ranges" do
    transliterator = I18n::Backend::Transliterator.get(
      Rule.new(:from => "fi", :to => "F", :match_ascii => true),
      :normalization_form => :nfkc
    )
    assert_equal "Fsh", transliterator.transliterate("ﬁsh")
    fragments = transliterator.transliterate_with_ranges("aﬁb")
    assert_equal [["a", (0...1)], ["F", (1...2)], ["b", (2...3)]], fragments
  end

  test "declarative rules work through a locale backend" do
    store_translations(:xx, :i18n => {:transliterate => {:rule => [
      Rule.new(:from => "ch", :to => "k", :match_ascii => true),
      Rule.new(:from => "ü", :to => "ue")
    ]}})
    assert_equal "kue", I18n.backend.transliterate(:xx, "chü")
    assert_equal "ue", I18n.transliterate("ü", :locale => :xx)
  end

  test "declarative rules validate their arguments" do
    assert_raises I18n::ArgumentError do
      Rule.new(:from => "", :to => "x")
    end
    assert_raises I18n::ArgumentError do
      Rule.new(:from => "x", :to => 1)
    end
    assert_raises I18n::ArgumentError do
      Rule.new(:from => "x", :to => "x", :left => 5)
    end
    assert_raises I18n::ArgumentError do
      I18n::Backend::Transliterator.get(["not a rule"])
    end
  end

  test "declarative transliterator handles empty strings" do
    transliterator = I18n::Backend::Transliterator.get(
      Rule.new(:from => "ü", :to => "ue")
    )
    assert_equal "", transliterator.transliterate("")
    assert_equal [], transliterator.transliterate_with_ranges("")
  end

  test "declarative transliterator raises for invalid UTF-8" do
    transliterator = I18n::Backend::Transliterator.get(
      Rule.new(:from => "ü", :to => "ue")
    )
    assert_raises ArgumentError do
      transliterator.transliterate("a\x92b")
    end
  end

end
