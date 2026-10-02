# frozen_string_literal: true

require 'test_helper'

class I18nAgreementTest < I18n::TestCase
  def setup
    super
    I18n.backend = I18n::Backend::Simple.new
  end

  def test_a_fragment_narrows_the_choices_of_all_other_fragments
    store_translations(:en, :phrase => agreeing_phrase)

    assert_equal 'el rojo libro', I18n.t(:phrase)
  end

  def test_caller_features_are_hard_constraints_when_selecting_forms
    store_translations(:en, :phrase => agreeing_phrase)

    assert_equal 'los rojos libros', I18n.t(:phrase, :agreement_features => { :number => :plural })
  end

  def test_caller_feature_conflicts_mark_the_conflicting_fragment
    store_translations(:en, :phrase => agreeing_phrase)

    error = assert_raises(I18n::AgreementConflict) do
      I18n.t(:phrase, :agreement_features => { :gender => :feminine })
    end

    assert_equal [[:noun]], error.conflicting_fragments
    assert_equal({ :gender => :feminine }, error.features)
  end

  def test_ambiguous_messages_are_not_resolved_by_fragment_or_form_order
    store_translations(:en, :phrase => ambiguous_phrase)

    error = assert_raises(I18n::AmbiguousAgreement) do
      I18n.t(:phrase)
    end

    assert_equal 4, error.combinations.size
  end

  def test_explicit_default_features_select_a_single_combination
    phrase = ambiguous_phrase(:default_features => { :gender => :feminine, :number => :plural })
    store_translations(:en, :phrase => phrase)

    assert_equal 'las rojas mesas', I18n.t(:phrase)
  end

  def test_agreement_can_be_followed_by_normal_interpolation
    phrase = I18n::Agreement::Message.new(
      :template => '%{article} %{noun} for %{owner}',
      :features => [:gender],
      :fragments => {
        :article => {
          :forms => {
            'el' => { :gender => :masculine },
            'la' => { :gender => :feminine }
          }
        },
        :noun => {
          :forms => {
            'libro' => { :gender => :masculine }
          }
        }
      }
    )

    assert_equal 'el libro for Ada', phrase.resolve({}, :owner => 'Ada')
  end

  def test_pairwise_compatible_fragments_can_have_no_global_solution
    store_translations(:en, :phrase => globally_impossible_phrase)

    error = assert_raises(I18n::AgreementConflict) do
      I18n.t(:phrase)
    end

    assert_equal [[:adjective, :noun, :determiner]], error.conflicting_fragments
  end

  def test_normal_interpolation_still_accepts_features_as_an_ordinary_value
    store_translations(:en, :plain => '%{features}')

    assert_equal 'ordinary', I18n.t(:plain, :features => 'ordinary')
    assert_equal 'ordinary', I18n.interpolate('%{features}', :features => 'ordinary')
    assert_equal 'ordinary', I18n.interpolate('%{agreement_features}', :agreement_features => 'ordinary')
  end

  def test_existing_pluralization_and_interpolation_are_unchanged
    store_translations(:en, :items => { :one => 'one %{count} item', :other => '%{count} items' })

    assert_equal 'one 1 item', I18n.t(:items, :count => 1)
    assert_equal '2 items', I18n.t(:items, :count => 2)
  end

  def test_agreement_runs_after_existing_pluralization
    store_translations(:en,
      :items => {
        :one => agreeing_phrase,
        :other => I18n::Agreement::Message.new(
          :template => '%{article} %{noun}',
          :features => [:gender, :number],
          :fragments => {
            :article => {
              :forms => {
                'las' => { :gender => :feminine, :number => :plural },
                'los' => { :gender => :masculine, :number => :plural }
              }
            },
            :noun => {
              :forms => {
                'cosas' => { :gender => :feminine, :number => :plural }
              }
            }
          }
        )
      }
    )

    assert_equal 'el rojo libro', I18n.t(:items, :count => 1)
    assert_equal 'las cosas', I18n.t(:items, :count => 2)
  end

  def test_agreement_messages_work_with_the_interpolation_compiler
    backend = Class.new(I18n::Backend::Simple) do
      include I18n::Backend::InterpolationCompiler
    end.new
    I18n.backend = backend
    store_translations(:en, :phrase => agreeing_phrase)

    assert_equal 'el rojo libro', I18n.t(:phrase)
  end

  private

  def agreeing_phrase
    I18n::Agreement::Message.new(
      :template => '%{article} %{adjective} %{noun}',
      :features => [:gender, :number],
      :default_features => { :number => :singular },
      :fragments => {
        :article => {
          :forms => {
            'el' => { :gender => :masculine, :number => :singular },
            'la' => { :gender => :feminine, :number => :singular },
            'los' => { :gender => :masculine, :number => :plural },
            'las' => { :gender => :feminine, :number => :plural }
          }
        },
        :adjective => {
          :forms => {
            'rojo' => { :gender => :masculine, :number => :singular },
            'roja' => { :gender => :feminine, :number => :singular },
            'rojos' => { :gender => :masculine, :number => :plural },
            'rojas' => { :gender => :feminine, :number => :plural }
          }
        },
        :noun => {
          :forms => {
            'libro' => { :gender => :masculine, :number => :singular },
            'libros' => { :gender => :masculine, :number => :plural }
          }
        }
      }
    )
  end

  def ambiguous_phrase(default_features: nil)
    I18n::Agreement::Message.new(
      :template => '%{article} %{adjective} %{noun}',
      :features => [:gender, :number],
      :default_features => default_features,
      :fragments => {
        :article => {
          :forms => {
            'el' => { :gender => :masculine, :number => :singular },
            'la' => { :gender => :feminine, :number => :singular },
            'los' => { :gender => :masculine, :number => :plural },
            'las' => { :gender => :feminine, :number => :plural }
          }
        },
        :adjective => {
          :forms => {
            'rojo' => { :gender => :masculine, :number => :singular },
            'roja' => { :gender => :feminine, :number => :singular },
            'rojos' => { :gender => :masculine, :number => :plural },
            'rojas' => { :gender => :feminine, :number => :plural }
          }
        },
        :noun => {
          :forms => {
            'libro' => { :gender => :masculine, :number => :singular },
            'mesa' => { :gender => :feminine, :number => :singular },
            'libros' => { :gender => :masculine, :number => :plural },
            'mesas' => { :gender => :feminine, :number => :plural }
          }
        }
      }
    )
  end

  def globally_impossible_phrase
    I18n::Agreement::Message.new(
      :template => '%{adjective} %{noun} %{determiner}',
      :features => [:gender, :number, :case],
      :fragments => {
        :adjective => {
          :forms => {
            'bon' => [
              { :gender => :masculine, :case => :nominative },
              { :gender => :feminine, :case => :accusative }
            ]
          }
        },
        :noun => {
          :forms => {
            'amo' => [
              { :gender => :masculine, :number => :singular },
              { :gender => :feminine, :number => :plural }
            ]
          }
        },
        :determiner => {
          :forms => {
            'das' => [
              { :number => :singular, :case => :accusative },
              { :number => :plural, :case => :nominative }
            ]
          }
        }
      }
    )
  end
end
