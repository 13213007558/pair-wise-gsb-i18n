# frozen_string_literal: true
require 'test_helper'

class CollationTest < I18n::TestCase
  def tiny_weights(version = 'tiny-1')
    {
      version: version,
      variable: [' ', ',', '-'],
      mappings: {
        ' ' => [10, 2, 2],
        ',' => [10, 2, 2],
        '-' => [10, 2, 2],
        '0' => [30, 2, 2],
        '1' => [30, 2, 2],
        '2' => [30, 2, 2],
        '9' => [30, 2, 2],
        'a' => [40, 2, 2],
        'A' => [40, 2, 8],
        'b' => [41, 2, 2],
        'B' => [41, 2, 8],
        'c' => [42, 2, 2],
        'C' => [42, 2, 8],
        'd' => [43, 2, 2],
        'e' => [44, 2, 2],
        'E' => [44, 2, 8],
        'h' => [47, 2, 2],
        'n' => [50, 2, 2],
        'u' => [55, 2, 2],
        'U' => [55, 2, 8],
        'x' => [59, 2, 2],
        'X' => [59, 2, 8],
        'à' => [40, 4, 2],
        'À' => [40, 4, 8],
        'é' => [44, 5, 2],
        'É' => [44, 5, 8],
        'ü' => [55, 12, 2],
        'Æ' => [[40, 2, 2], [44, 2, 2]],
        'æ' => [[40, 2, 2], [44, 2, 2]],
        'ß' => [[52, 2, 2], [52, 2, 2]]
      }
    }
  end

  def tiny_tailorings
    {
      root: {},
      xx: {
        'ch' => [[42, 9, 2]]
      }
    }
  end

  def test_sort_keys_are_reusable_and_deterministic
    collator = I18n::Collation::Collator.new(weights: tiny_weights)
    first = collator.sort_key('é')
    second = collator.sort_key('é')

    assert_equal collator.fingerprint, first.fingerprint
    assert_equal first, second
    assert_equal 0, first <=> second
    assert_equal first.to_s, second.to_s
    assert_equal [[44], [5], [2]], first.to_a
    assert first.frozen?
    assert first.levels.all?(&:frozen?)
  end

  def test_multilevel_weights_ignore_case_and_accents_at_lower_strengths
    collator = I18n::Collation::Collator.new(weights: tiny_weights)

    assert_equal(-1, collator.compare('a', 'b'))
    assert_equal(-1, collator.compare('é', 'eu'))
    assert_equal(-1, collator.compare('e', 'É'))
    assert_equal(-1, collator.compare('ex', 'Éx'))
    assert_equal 1, collator.compare('Éx', 'EX')
    assert_equal(-1, collator.compare('ü', 'ux'))

    primary = I18n::Collation::Collator.new(weights: tiny_weights, strength: 1)
    assert_equal 0, primary.compare('A', 'à')

    secondary = I18n::Collation::Collator.new(weights: tiny_weights, strength: 2)
    assert_equal 0, secondary.compare('e', 'E')
    assert_equal(-1, secondary.compare('e', 'é'))
  end

  def test_nfd_canonical_equivalence
    collator = I18n::Collation::Collator.new(weights: tiny_weights)

    assert_equal collator.sort_key('é').to_a, collator.sort_key("e\u0301").to_a
    assert_equal 0, collator.compare('À', "A\u0300")
  end

  def test_locale_tailoring_changes_contraction_order
    root = I18n::Collation::Collator.new(locale: :root, weights: tiny_weights, tailorings: tiny_tailorings)
    xx = I18n::Collation::Collator.new(locale: :xx, weights: tiny_weights, tailorings: tiny_tailorings)

    assert_equal(%w[cd ch], root.collate(%w[ch cd]))
    assert_equal(%w[ch cd], xx.collate(%w[ch cd]))
    assert_equal [[42], [9], [2]], xx.sort_key('ch').to_a
  end

  def test_locale_tailorings_apply_to_parents
    xx = I18n::Collation::Collator.new(locale: :'xx-XX', weights: tiny_weights, tailorings: tiny_tailorings)

    assert_equal [[42], [9], [2]], xx.sort_key('ch').to_a
  end

  def test_expansion_orders_ligature_by_its_sequence
    collator = I18n::Collation::Collator.new(weights: tiny_weights)

    assert_equal 0, collator.compare('Æ', 'ae')
    assert_equal(%w[ad æ], collator.collate(%w[æ ad]))
    assert_equal [[52, 52], [2, 2], [2, 2]], collator.sort_key('ß').to_a
  end

  def test_punctuation_can_be_ignored
    with_punctuation = I18n::Collation::Collator.new(weights: tiny_weights, ignore_punctuation: false)
    without_punctuation = I18n::Collation::Collator.new(weights: tiny_weights, ignore_punctuation: true)

    assert_equal(-1, with_punctuation.compare('a b', 'ab'))
    assert_equal 0, without_punctuation.compare('a-b', 'ab')
    assert_equal 0, without_punctuation.compare('a,b', 'ab')
    assert_equal with_punctuation.sort_key("a b").to_a.size, 3
    assert_equal without_punctuation.sort_key("a b").to_a, without_punctuation.sort_key('ab').to_a
  end

  def test_numeric_fragments_use_natural_order
    text = I18n::Collation::Collator.new(weights: tiny_weights)
    numeric = I18n::Collation::Collator.new(weights: tiny_weights, numeric: true)

    assert_equal(%w[2 10], text.collate(%w[10 2]))
    assert_equal(%w[1 2 10 20], numeric.collate(%w[10 20 2 1]))
    assert_equal(-1, numeric.compare('a2', 'a10'))
    assert_equal(%w[1 01 2], numeric.collate(%w[01 2 1]))
    assert_equal(-1, numeric.compare('1', '10'))
  end

  def test_stable_sort_keeps_equal_items_in_original_order
    collator = I18n::Collation::Collator.new(weights: tiny_weights, strength: 1)
    assert_equal %w[A à a], collator.collate(['A', 'à', 'a'])
  end

  def test_incompatible_sort_keys_are_not_compared
    version_one = I18n::Collation::Collator.new(weights: tiny_weights('one'))
    version_two = I18n::Collation::Collator.new(weights: tiny_weights('two'))
    root = I18n::Collation::Collator.new(locale: :root, weights: tiny_weights, tailorings: tiny_tailorings)
    xx = I18n::Collation::Collator.new(locale: :xx, weights: tiny_weights, tailorings: tiny_tailorings)
    ignoring = I18n::Collation::Collator.new(weights: tiny_weights, ignore_punctuation: true)

    assert_raises(I18n::Collation::IncompatibleSortKey) { version_one.sort_key('a') <=> version_two.sort_key('a') }
    assert_raises(I18n::Collation::IncompatibleSortKey) { root.sort_key('a') <=> xx.sort_key('a') }
    assert_raises(I18n::Collation::IncompatibleSortKey) { version_one.sort_key('a') <=> ignoring.sort_key('a') }
  end

  def test_unknown_characters_raise_a_weight_error
    collator = I18n::Collation::Collator.new(weights: tiny_weights)

    error = assert_raises(I18n::Collation::UndefinedWeight) { collator.sort_key('z') }
    assert_match(/missing collation weight/, error.message)
  end

  def test_loads_official_uca_allkeys_vector_offline
    path = File.expand_path('../lib/i18n/collation/data/ducet-16.0.0-minimal.txt', __dir__)
    collator = I18n::Collation::Collator.new(weights: path, ignore_punctuation: true)

    assert_equal '16.0.0', collator.weights_version
    assert_equal 0, collator.compare('é', "e\u0301")
    assert_equal(-1, collator.compare('e', 'é'))
    assert_equal(-1, collator.compare('é', 'É'))
    assert_equal(-1, collator.compare('n', 'ñ'))
    assert_equal(-1, collator.compare('u', 'ü'))
  end

  def test_global_configuration_entry
    I18n.configure_collation(locale: :xx, weights: tiny_weights, tailorings: tiny_tailorings)
    I18n.locale = :xx

    assert_equal [[42], [9], [2]], I18n.sort_key('ch').to_a
    assert_equal 1, I18n.compare('cd', 'ch')
    assert_equal %w[ch cd], I18n.collate(%w[cd ch])
    assert_equal %w[ch cd], I18n.sort_names(%w[cd ch])
  end

  def test_global_entry_derives_a_locale_compatible_collator
    I18n.configure_collation(locale: :root, weights: tiny_weights, tailorings: tiny_tailorings)

    assert_equal %w[ch cd], I18n.collate(%w[cd ch], locale: :xx)
    assert_raises(I18n::Collation::IncompatibleSortKey) do
      I18n.sort_key('a') <=> I18n.sort_key('a', locale: :xx)
    end
  end

  def test_missing_global_collation_is_explicit
    error = assert_raises(I18n::Collation::MissingCollation) { I18n.sort_key('a') }
    assert_match(/configure I18n\.collation/, error.message)
  end

  def test_module_constructor
    key = I18n::Collation.sort_key('a', weights: tiny_weights)

    assert_instance_of I18n::Collation::SortKey, key
    assert_equal(-1, I18n::Collation.compare('a', 'b', weights: tiny_weights))
  end
end
