# encoding: utf-8
require 'test_helper'

class I18nBackendRuleTransliteratorTest < I18n::TestCase
  Segment = I18n::Backend::Transliterator::Segment

  def setup
    super
    I18n.backend = I18n::Backend::Simple.new
  end

  def rule_transliterator(rules, **options)
    I18n::Backend::Transliterator::RuleTransliterator.new(rules, **options)
  end

  # -- construction -------------------------------------------------------

  test "an array rule builds a rule transliterator" do
    transliterator = rule_transliterator([{ "ü" => "ue" }])
    assert_instance_of I18n::Backend::Transliterator::RuleTransliterator, transliterator
  end

  test "Transliterator.get returns a RuleTransliterator for an array" do
    assert_kind_of I18n::Backend::Transliterator::RuleTransliterator,
                   I18n::Backend::Transliterator.get([])
  end

  test "non hash entries raise an argument error" do
    error = assert_raises(I18n::ArgumentError) { rule_transliterator(["nope"]) }
    assert_match(/must be hashes/, error.message)
  end

  test "declarative rules require a non empty pattern" do
    error = assert_raises(I18n::ArgumentError) do
      rule_transliterator([{ "pattern" => "", "replacement" => "x" }])
    end
    assert_match(/pattern/, error.message)
  end

  test "a pattern key without a replacement is reported as missing replacement" do
    error = assert_raises(I18n::ArgumentError) do
      rule_transliterator([{ "pattern" => "x" }])
    end
    assert_match(/replacement/, error.message)
  end

  test "declarative rules require a replacement" do
    error = assert_raises(I18n::ArgumentError) do
      rule_transliterator([{ "pattern" => "x" }])
    end
    assert_match(/replacement/, error.message)
  end

  test "unknown declarative keys raise an argument error" do
    error = assert_raises(I18n::ArgumentError) do
      rule_transliterator([{ "pattern" => "x", "replacement" => "y", "bogus" => 1 }])
    end
    assert_match(/bogus/, error.message)
  end

  test "priority must be an integer" do
    assert_raises(I18n::ArgumentError) do
      rule_transliterator([{ "pattern" => "x", "replacement" => "y", "priority" => "high" }])
    end
  end

  test "unknown normalization forms raise an argument error" do
    assert_raises(I18n::ArgumentError) do
      rule_transliterator([], normalization_form: :nfcx)
    end
  end

  test "invalid utf-8 raises an argument error" do
    transliterator = rule_transliterator([{ "x" => "y" }])
    assert_raises(ArgumentError) { transliterator.transliterate("a\x92b") }
  end

  # -- multi character input ---------------------------------------------

  test "multiple input characters can map to one syllable" do
    transliterator = rule_transliterator([{ "ch" => "tch" }])
    assert_equal "tchat", transliterator.transliterate("chat")
  end

  test "plain shorthand rules may contain several pairs in one entry" do
    transliterator = rule_transliterator([{ "ch" => "tch", "ü" => "ue" }])
    assert_equal "tchessue", transliterator.transliterate("chessü")
  end

  test "declarative rules accept string and symbol keys (as from yml)" do
    transliterator = rule_transliterator([{ pattern: "ch", replacement: "tch" }])
    assert_equal "tchat", transliterator.transliterate("chat")
  end

  test "an empty replacement deletes the match" do
    transliterator = rule_transliterator([{ "pattern" => "h", "replacement" => "" }])
    assert_equal "a", transliterator.transliterate("hah")
  end

  # -- longest valid match ------------------------------------------------

  test "the longest valid pattern wins by default" do
    transliterator = rule_transliterator([{ "sch" => "sh" }, { "sc" => "sk" }])
    assert_equal "shiff", transliterator.transliterate("schiff")
    assert_equal "skiff", transliterator.transliterate("sciff")
  end

  test "overlapping same length rules resolve by declaration order" do
    transliterator = rule_transliterator([
      { "pattern" => "ch", "replacement" => "one" },
      { "pattern" => "ch", "replacement" => "two" }
    ])
    assert_equal "one", transliterator.transliterate("ch")
  end

  test "explicit priority beats the default longest match" do
    transliterator = rule_transliterator([
      { "pattern" => "ch", "replacement" => "long" },
      { "pattern" => "c", "replacement" => "short", "priority" => 5 }
    ])
    assert_equal "shorth", transliterator.transliterate("ch")
  end

  test "higher priority wins regardless of declaration order" do
    transliterator = rule_transliterator([
      { "pattern" => "ch", "replacement" => "low", "priority" => 1 },
      { "pattern" => "ch", "replacement" => "high", "priority" => 9 }
    ])
    assert_equal "high", transliterator.transliterate("ch")
  end

  test "context constrained rules win ties over unconstrained rules" do
    transliterator = rule_transliterator([
      { "pattern" => "c", "replacement" => "k" },
      { "pattern" => "c", "replacement" => "ts", "right" => %w[i e] }
    ])
    assert_equal "tsitseka", transliterator.transliterate("ciceca")
  end

  test "context constrained rules only fire where the context holds" do
    transliterator = rule_transliterator([
      { "pattern" => "ch", "replacement" => "X", "left" => "word_boundary" }
    ])
    assert_equal "ach X", transliterator.transliterate("ach ch")
  end

  # -- context ------------------------------------------------------------

  test "left literal context must be adjacent and is not consumed" do
    transliterator = rule_transliterator([
      { "pattern" => "a", "replacement" => "@", "left" => "x" }
    ])
    assert_equal "x@ba", transliterator.transliterate("xaba")
  end

  test "right literal context must be adjacent and is not consumed" do
    transliterator = rule_transliterator([
      { "pattern" => "a", "replacement" => "@", "right" => "b" }
    ])
    assert_equal "@bca", transliterator.transliterate("abca")
  end

  test "start and end anchors constrain matches" do
    transliterator = rule_transliterator([
      { "pattern" => "a", "replacement" => "1", "left" => "start" },
      { "pattern" => "a", "replacement" => "2", "right" => "end" }
    ])
    assert_equal "1b2", transliterator.transliterate("aba")
  end

  test "context alternatives accept any listed option" do
    transliterator = rule_transliterator([
      { "pattern" => "a", "replacement" => "@", "right" => %w[b c] }
    ])
    assert_equal "b@cad", transliterator.transliterate("bacad")
  end

  test "symbol anchors work like the documented string anchors" do
    transliterator = rule_transliterator([
      { pattern: "a", replacement: "@", right: :end }
    ])
    assert_equal "ba@", transliterator.transliterate("baa")
  end

  test "invalid context anchors raise an argument error" do
    assert_raises(I18n::ArgumentError) do
      rule_transliterator([{ "pattern" => "a", "replacement" => "@", "left" => 42 }])
    end
  end

  # -- unicode normalization ---------------------------------------------

  test "decomposed input matches composed patterns under nfc" do
    transliterator = rule_transliterator([{ "ü" => "ue" }])
    decomposed = [117, 776].pack("U*") # "u" + COMBINING DIAERESIS
    assert_equal "ue", transliterator.transliterate(decomposed)
    assert_equal "ueben", transliterator.transliterate(decomposed + "ben")
  end

  test "matching happens under the declared nfd normalization form" do
    transliterator = rule_transliterator(
      [{ "pattern" => "ü", "replacement" => "ue" }], normalization_form: :nfd
    )
    assert_equal "Muenchen", transliterator.transliterate("München")
  end

  test "nfkc normalizes compatibility characters" do
    transliterator = rule_transliterator([], normalization_form: :nfkc)
    assert_equal "file", transliterator.transliterate("ﬁle")
  end

  test "normalization can be disabled" do
    transliterator = rule_transliterator([{ "ü" => "ue" }], normalization_form: :none)
    decomposed = [117, 776].pack("U*")
    refute_equal "ue", transliterator.transliterate(decomposed)
  end

  test "combining marks form one grapheme cluster and one segment" do
    transliterator = rule_transliterator([{ "ü" => "ue" }])
    input = [117, 776].pack("U*")
    segments = transliterator.transliterate_segments(input)
    assert_equal ["ue"], segments.map(&:text)
    assert_equal 0...2, segments.first.input_range
  end

  # -- default mapping inheritance and replacement -----------------------

  test "default latin approximations are inherited" do
    transliterator = rule_transliterator([])
    assert_equal "AEroskobing", transliterator.transliterate("Ærøskøbing")
  end

  test "locale rules override the inherited defaults" do
    transliterator = rule_transliterator([{ "ü" => "u" }])
    assert_equal "Jurgen", transliterator.transliterate("Jürgen")
  end

  test "unknown non ascii characters use the replacement option" do
    transliterator = rule_transliterator([])
    assert_equal "abc?", transliterator.transliterate("abcſ")
    assert_equal "abc#", transliterator.transliterate("abcſ", "#")
    assert_equal "abcſ", transliterator.transliterate("abcſ", :none)
  end

  test "ascii input is always passed through" do
    transliterator = rule_transliterator([])
    (0..127).each do |byte|
      char = [byte].pack("U")
      assert_equal char, transliterator.transliterate(char)
    end
  end

  # -- single pass --------------------------------------------------------

  test "replacement text is never fed back through the rules" do
    transliterator = rule_transliterator([
      { "pattern" => "a", "replacement" => "ch" },
      { "pattern" => "ch", "replacement" => "X" }
    ])
    assert_equal "ch", transliterator.transliterate("a")
    assert_equal "X", transliterator.transliterate("ch")
  end

  # -- segments / input intervals ----------------------------------------

  test "segments return the output text and original input intervals" do
    transliterator = rule_transliterator([{ "ch" => "X" }])
    segments = transliterator.transliterate_segments("ach")
    assert_equal ["a", "X"], segments.map(&:text)
    assert_equal 0...1, segments.first.input_range
    assert_equal 1...3, segments.last.input_range
  end

  test "segment slices reproduce the original input" do
    transliterator = rule_transliterator([{ "pattern" => "ü", "replacement" => "ue" }])
    input = [117, 776].pack("U*") + "ben"
    segments = transliterator.transliterate_segments(input)
    assert_equal input, segments.map { |segment| segment.slice_input(input) }.join
  end

  test "segments cover the input without gaps or overlaps" do
    transliterator = rule_transliterator([
      { "pattern" => "ch", "replacement" => "K", "left" => "word_boundary" },
      { "ü" => "ue" }
    ])
    input = "chüch!"
    segments = transliterator.transliterate_segments(input)
    ranges = segments.map(&:input_range)
    assert_equal (0...input.codepoints.length), ranges.first.begin...ranges.last.end
    ranges.each_cons(2) { |a, b| assert_equal a.end, b.begin }
    assert_equal "KueK!", segments.map(&:text).join
  end

  test "matched segments flag rule output and passthrough output differently" do
    transliterator = rule_transliterator([{ "ü" => "ue" }])
    segments = transliterator.transliterate_segments("aüb")
    assert_equal [false, true, false], segments.map(&:matched?)
  end

  test "unknown character segments keep their interval and are unmatched" do
    transliterator = rule_transliterator([{ "ü" => "ue" }])
    segments = transliterator.transliterate_segments("ü日")
    assert_equal ["ue", "?"], segments.map(&:text)
    assert_equal 1...2, segments.last.input_range
    refute segments.last.matched?
  end

  # -- determinism --------------------------------------------------------

  test "the same input always yields the exact same result" do
    transliterator = rule_transliterator([
      { "pattern" => "ch", "replacement" => "K", "left" => "word_boundary" },
      { "pattern" => "sch", "replacement" => "SH" },
      { "pattern" => "ü", "replacement" => "ue" },
      { "pattern" => "a", "replacement" => "@", "right" => "end" }
    ])
    input = "Die schüchternen Schüler chanten a"
    20.times do
      assert_equal transliterator.transliterate(input), transliterator.transliterate(input)
      assert_equal transliterator.transliterate_segments(input),
                   transliterator.transliterate_segments(input)
    end
  end

  test "word boundary example is stable across repeated runs" do
    transliterator = rule_transliterator([
      { "pattern" => "ch", "replacement" => "tch", "left" => "word_boundary" }
    ])
    expected = "tchorus aching"
    20.times { assert_equal expected, transliterator.transliterate("chorus aching") }
  end

  test "combining character input is stable across repeated runs" do
    transliterator = rule_transliterator([{ "ü" => "ue" }])
    inputs = ["München", [117, 776].pack("U*") + "ben", "Mü" + [776].pack("U*")]
    inputs.each do |input|
      expected = transliterator.transliterate(input)
      20.times { assert_equal expected, transliterator.transliterate(input) }
    end
  end

  test "mixed composed and decomposed input with overlapping rules is stable" do
    transliterator = rule_transliterator([
      { "pattern" => "ch", "replacement" => "X", "left" => "word_boundary" },
      { "pattern" => "ch", "replacement" => "Y" },
      { "ü" => "ue" }
    ])
    input = "chüch " + [0x0063, 0x0308].pack("U*") + "x Ch"
    expected = transliterator.transliterate(input)
    segments = transliterator.transliterate_segments(input)
    20.times do
      assert_equal expected, transliterator.transliterate(input)
      assert_equal segments, transliterator.transliterate_segments(input)
    end
    assert_equal expected, segments.map(&:text).join
    assert_equal input, segments.map { |segment| segment.slice_input(input) }.join
  end

  test "segments rejoin to the transliterated string" do
    transliterator = rule_transliterator([{ "sch" => "sh" }, { "ch" => "k" }])
    input = "schichtwechsel"
    segments = transliterator.transliterate_segments(input)
    assert_equal transliterator.transliterate(input), segments.map(&:text).join
  end

  # -- backend integration ------------------------------------------------

  test "array rules can be stored per locale as translations" do
    store_translations(:xx, :i18n => { :transliterate => { :rule => [
      { "pattern" => "ch", "replacement" => "K", "left" => "word_boundary" },
      { "ü" => "ue" }
    ] } })
    assert_equal "KueK", I18n.backend.transliterate(:xx, "chüch")
  end

  test "transliterate_segments is available through the backend" do
    store_translations(:xx, :i18n => { :transliterate => { :rule => [
      { "pattern" => "ch", "replacement" => "K" }
    ] } })
    segments = I18n.backend.transliterate_segments(:xx, "ch")
    assert_equal ["K"], segments.map(&:text)
    assert_equal 0...2, segments.first.input_range
  end

  test "transliterate_segments is available on I18n" do
    store_translations(:xx, :i18n => { :transliterate => { :rule => [
      { "pattern" => "ch", "replacement" => "K" }
    ] } })
    assert_kind_of Segment, I18n.transliterate_segments("ch", :locale => :xx).first
  end

  test "transliterate_segments raises for proc rules" do
    store_translations(:xx, :i18n => { :transliterate => { :rule => ->(s) { s } } })
    assert_raises(I18n::ArgumentError) do
      I18n.backend.transliterate_segments(:xx, "ch")
    end
  end

  test "hash transliterator also reports segments and intervals" do
    transliterator = I18n::Backend::Transliterator.get({ "ü" => "ue" })
    segments = transliterator.transliterate_segments("aüſ")
    assert_equal ["a", "ue", "?"], segments.map(&:text)
    assert_equal [false, true, false], segments.map(&:matched?)
    assert_equal 1...2, segments[1].input_range
    assert_equal "ü", segments[1].slice_input("aüſ")
  end
end
