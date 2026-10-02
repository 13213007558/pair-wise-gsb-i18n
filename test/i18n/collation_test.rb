# frozen_string_literal: true

require 'test_helper'

class CollationTest < Minitest::Test
  def custom_collator(**overrides)
    base = I18n.collation(
      weights: {
        'a' => [[[1], [5], [5]]],
        'A' => [[[1], [5], [28]]],
        'á' => [[[1], [6], [5]]],
        'b' => [[[2], [5], [5]]],
        'c' => [[[3], [5], [5]]],
        'h' => [[[4], [5], [5]]],
        'ch' => [[[2], [5], [5]]],
        'ß' => [[[5], [5], [5]], [[5], [5], [5]]],
        's' => [[[5], [5], [5]]],
        '0' => [[[6], [5], [5]]],
        '1' => [[[6], [5], [5]]],
        '2' => [[[6], [5], [5]]],
        '9' => [[[6], [5], [5]]],
        '.' => [[[7], [5], [5]]]
      },
      locale: :cs
    )
    overrides.empty? ? base : base.with(table: base.table, locale: :cs, **overrides)
  end

  def test_generates_reusable_deterministic_sort_keys
    collator = custom_collator
    left = collator.sort_key('a')
    right = collator['a']

    assert_equal left, right
    assert_equal left.to_a, right.to_a
  end

  def test_multi_level_weights
    collator = custom_collator

    assert_equal(-1, collator.compare('a', 'á'))
    assert_equal(-1, collator.compare('á', 'b'))
    assert_equal(-1, collator.compare('a', 'A'))
    assert_equal(collator.sort_key('a').to_a, collator.sort_key('a').to_a)
  end

  def test_canonical_equivalence
    collator = custom_collator
    decomposed = "a\u0301"

    assert_equal 0, collator.compare('á', decomposed)
    assert_equal collator.sort_key('á'), collator.sort_key(decomposed)
  end

  def test_contraction_uses_longest_match
    collator = custom_collator

    assert_equal %w[ch c h], collator.sort(%w[h ch c])
  end

  def test_expansion
    collator = custom_collator

    assert_equal 0, collator.compare('ß', 'ss')
  end

  def test_stable_sorting_preserves_equal_item_order
    collator = custom_collator
    first = Struct.new(:name).new('same')
    second = Struct.new(:name).new('same')

    assert_equal [first, second], collator.sort_by([first, second], &:name)
  end

  def test_numeric_fragments
    collator = custom_collator(numeric: true)

    assert_equal %w[2 10], collator.sort(%w[10 2])
    assert_equal(-1, collator.compare('2', '10'))
  end

  def test_ignoring_punctuation
    collator = custom_collator(ignore_punctuation: true)

    assert_equal 0, collator.compare('a', 'a.')
  end

  def test_locale_tailoring_is_part_of_config_fingerprint
    czech = custom_collator
    german_weights = czech.table.entries.merge('h' => [[[1], [5], [5]]])
    german = I18n.collation(weights: german_weights, locale: :de)

    refute czech.compatible?(german)
    assert_equal(-1, german.compare('h', 'b'))
    assert_raises(I18n::Collation::IncompatibleCollationError) do
      czech.sort_key('a') < german.sort_key('a')
    end
  end

  def test_official_non_ignorable_short_sample
    collator = I18n.collation(weights: :uca)
    fixture = File.expand_path('../fixtures/collation/CollationTest_NON_IGNORABLE_SHORT-15.1-sample.txt', __dir__)
    previous = nil
    comparisons = 0

    File.foreach(fixture, encoding: 'UTF-8') do |line|
      line = line.chomp
      next if line.empty? || line.start_with?('#')

      string = line.split.map { |codepoint| codepoint.to_i(16) }.pack('U*')
      if previous
        assert(collator.compare(previous, string) <= 0, [previous, string, line].inspect)
        comparisons += 1
      end
      previous = string
    end

    assert_equal 704, comparisons
    assert_equal '15.1.0', collator.table.version
  end
end
