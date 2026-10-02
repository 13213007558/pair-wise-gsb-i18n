require 'test_helper'

class I18nBackendAgreementTest < I18n::TestCase
  class Backend < I18n::Backend::Simple
    include I18n::Backend::Agreement
  end

  # A tiny made-up lexicon. Nouns, verbs and adjectives inflect for the
  # features :gender (:m, :f) and :number (:sg, :pl).
  def setup
    super
    I18n.backend = Backend.new
    store_translations(:xx,
      :hello => 'Hello',
      :greet => 'Hello %{name}',
      :inbox => { :one => 'one message', :other => '%{count} messages' },
      :subtree => { :leaf => 'a leaf' },
      :not_an_agreement_message => { :agreement => 'just a string' },
      :sentence => {
        :agreement => {
          :on       => [:gender, :number],
          :template => '%{subject} %{verb} %{adjective}',
          :segments => {
            :subject => {
              :forms => [
                { :features => { :gender => :m, :number => :sg }, :text => 'der Hund' },
                { :features => { :gender => :f, :number => :sg }, :text => 'die Katze' }
              ]
            },
            :verb => {
              :forms => [
                { :features => { :number => :sg }, :text => 'ist' },
                { :features => { :number => :pl }, :text => 'sind' }
              ]
            },
            :adjective => {
              :forms => [
                { :features => { :gender => :m, :number => :sg }, :text => 'grosser' },
                { :features => { :gender => :f, :number => :sg }, :text => 'grosse' },
                { :features => { :gender => :m, :number => :pl }, :text => 'grossen' },
                { :features => { :gender => :f, :number => :pl }, :text => 'grossen' }
              ]
            }
          }
        }
      },
      :narrowed => {
        :agreement => {
          :on       => [:gender, :number],
          :template => '%{subject} %{verb} %{adjective}',
          :segments => {
            # this segment only has a feminine plural form, so it narrows
            # down the choices of every other segment
            :subject => {
              :forms => [
                { :features => { :gender => :f, :number => :pl }, :text => 'die Katzen' }
              ]
            },
            :verb => {
              :forms => [
                { :features => { :number => :sg }, :text => 'ist' },
                { :features => { :number => :pl }, :text => 'sind' }
              ]
            },
            :adjective => {
              :forms => [
                { :features => { :gender => :m, :number => :sg }, :text => 'grosser' },
                { :features => { :gender => :f, :number => :pl }, :text => 'grossen' }
              ]
            }
          }
        }
      },
      :pairwise_compatible => {
        :agreement => {
          :on       => [:gender, :number],
          :template => '%{first} %{second} %{third}',
          :segments => {
            # any two of these segments share a feature combination, but no
            # single combination satisfies all three of them
            :first => {
              :forms => [
                { :features => { :gender => :m, :number => :sg }, :text => 'a1' },
                { :features => { :gender => :f, :number => :pl }, :text => 'a2' }
              ]
            },
            :second => {
              :forms => [
                { :features => { :gender => :m, :number => :sg }, :text => 'b1' },
                { :features => { :gender => :f, :number => :sg }, :text => 'b2' }
              ]
            },
            :third => {
              :forms => [
                { :features => { :gender => :f, :number => :pl }, :text => 'c1' },
                { :features => { :gender => :f, :number => :sg }, :text => 'c2' }
              ]
            }
          }
        }
      },
      :ambiguous => {
        :agreement => {
          :on       => [:gender],
          :template => '%{noun} %{adjective}',
          :segments => {
            :noun => {
              :forms => [
                { :features => { :gender => :m }, :text => 'Hund' },
                { :features => { :gender => :f }, :text => 'Katze' }
              ]
            },
            :adjective => {
              :forms => [
                { :features => { :gender => :m }, :text => 'grosser' },
                { :features => { :gender => :f }, :text => 'grosse' }
              ]
            }
          }
        }
      },
      :with_invariant => {
        :agreement => {
          :on       => [:number],
          :template => '%{subject} %{verb} heute',
          :segments => {
            :subject => {
              :forms => [
                { :features => { :number => :sg }, :text => 'der Hund' },
                { :features => { :number => :pl }, :text => 'die Hunde' }
              ]
            },
            :verb => {
              :forms => [
                { :features => { :number => :sg }, :text => 'schläft' },
                { :features => { :number => :pl }, :text => 'schlafen' }
              ]
            }
          }
        }
      },
      :with_name => {
        :agreement => {
          :on       => [:gender],
          :template => '%{noun} grüsst %{name}',
          :segments => {
            :noun => {
              :forms => [
                { :features => { :gender => :m }, :text => 'der Hund' },
                { :features => { :gender => :f }, :text => 'die Katze' }
              ]
            }
          }
        }
      }
    )
  end

  test "agreement solves the message before choosing forms: caller constraints narrow other segments" do
    assert_equal 'die Katze ist grosse', I18n.t(:sentence, :locale => :xx, :agreement => { :gender => :f })
    assert_equal 'der Hund ist grosser', I18n.t(:sentence, :locale => :xx, :agreement => { :gender => :m })
  end

  test "agreement solves the message before choosing forms: a segment narrows the other segments" do
    # picking the first form of each segment in order would wrongly give
    # "die Katzen ist grosser"; solving first yields the consistent forms
    assert_equal 'die Katzen sind grossen', I18n.t(:narrowed, :locale => :xx)
  end

  test "agreement accepts caller constraints given as strings" do
    assert_equal 'die Katze ist grosse', I18n.t(:sentence, :locale => :xx, :agreement => { 'gender' => :f })
  end

  test "agreement supports invariant segments given as plain strings" do
    assert_equal 'der Hund schläft heute', I18n.t(:with_invariant, :locale => :xx, :agreement => { :number => :sg })
    assert_equal 'die Hunde schlafen heute', I18n.t(:with_invariant, :locale => :xx, :agreement => { :number => :pl })
  end

  test "agreement interpolates the caller values that are not segments" do
    assert_equal 'die Katze grüsst Emma', I18n.t(:with_name, :locale => :xx, :name => 'Emma', :agreement => { :gender => :f })
  end

  test "agreement raises AgreementConflict naming the conflicting segments when constraints cannot be satisfied" do
    exception = assert_raises(I18n::AgreementConflict) do
      I18n.t(:sentence, :locale => :xx, :agreement => { :gender => :f, :number => :pl })
    end
    assert_equal [:subject], exception.segments
    assert_equal({ :gender => :f, :number => :pl }, exception.constraints)
  end

  test "agreement raises AgreementConflict for pairwise compatible but globally unsolvable segments" do
    exception = assert_raises(I18n::AgreementConflict) do
      I18n.t(:pairwise_compatible, :locale => :xx)
    end
    assert_equal [:first, :second, :third], exception.segments
  end

  test "agreement reports the possible feature combinations of an unconstrained ambiguous message" do
    exception = assert_raises(I18n::AmbiguousAgreement) { I18n.t(:sentence, :locale => :xx) }
    assert_equal [{ :gender => :m, :number => :sg }, { :gender => :f, :number => :sg }], exception.solutions
    # a caller constraint resolves the same message to a unique solution
    assert_equal 'die Katze ist grosse', I18n.t(:sentence, :locale => :xx, :agreement => { :gender => :f })
  end

  test "agreement raises AmbiguousAgreement when several combinations remain and no default rule exists" do
    exception = assert_raises(I18n::AmbiguousAgreement) do
      I18n.t(:ambiguous, :locale => :xx)
    end
    assert_equal [{ :gender => :m }, { :gender => :f }], exception.solutions
  end

  test "agreement picks the solution matching an explicit default rule" do
    store_translations(:xx, :with_default => {
      :agreement => {
        :on       => [:gender],
        :default  => { :gender => :f },
        :template => '%{noun} %{adjective}',
        :segments => {
          :noun => {
            :forms => [
              { :features => { :gender => :m }, :text => 'Hund' },
              { :features => { :gender => :f }, :text => 'Katze' }
            ]
          },
          :adjective => {
            :forms => [
              { :features => { :gender => :m }, :text => 'grosser' },
              { :features => { :gender => :f }, :text => 'grosse' }
            ]
          }
        }
      }
    })
    assert_equal 'Katze grosse', I18n.t(:with_default, :locale => :xx)
    # caller constraints are hard constraints and win over the default rule
    assert_equal 'Hund grosser', I18n.t(:with_default, :locale => :xx, :agreement => { :gender => :m })
  end

  test "agreement raises AmbiguousAgreement when the default rule matches no solution" do
    store_translations(:xx, :useless_default => {
      :agreement => {
        :on       => [:gender],
        :default  => { :gender => :neuter },
        :template => '%{noun}',
        :segments => {
          :noun => {
            :forms => [
              { :features => { :gender => :m }, :text => 'Hund' },
              { :features => { :gender => :f }, :text => 'Katze' }
            ]
          }
        }
      }
    })
    assert_raises(I18n::AmbiguousAgreement) { I18n.t(:useless_default, :locale => :xx) }
  end

  test "agreement raises InvalidAgreementData for malformed messages" do
    store_translations(:xx,
      :no_template => { :agreement => { :on => [:gender], :segments => { :noun => 'Hund' } } },
      :no_segments => { :agreement => { :on => [:gender], :template => '%{noun}' } },
      :no_on       => { :agreement => { :template => '%{noun}', :segments => { :noun => 'Hund' } } },
      :no_text     => { :agreement => { :on => [:gender], :template => '%{noun}',
                        :segments => { :noun => { :forms => [{ :features => { :gender => :m } }] } } } }
    )
    assert_raises(I18n::InvalidAgreementData) { I18n.t(:no_template, :locale => :xx) }
    assert_raises(I18n::InvalidAgreementData) { I18n.t(:no_segments, :locale => :xx) }
    assert_raises(I18n::InvalidAgreementData) { I18n.t(:no_on, :locale => :xx) }
    assert_raises(I18n::InvalidAgreementData) { I18n.t(:no_text, :locale => :xx) }
  end

  test "agreement does not mutate the stored translation data" do
    I18n.t(:sentence, :locale => :xx, :agreement => { :gender => :f })
    entry = translations[:xx][:sentence]
    assert_equal '%{subject} %{verb} %{adjective}', entry[:agreement][:template]
    assert_equal 2, entry[:agreement][:segments][:subject][:forms].size
  end

  test "plain strings are not affected by the agreement module" do
    assert_equal 'Hello', I18n.t(:hello, :locale => :xx)
  end

  test "plain interpolation is not affected by the agreement module" do
    assert_equal 'Hello Emma', I18n.t(:greet, :locale => :xx, :name => 'Emma')
  end

  test "pluralization is not affected by the agreement module" do
    assert_equal 'one message', I18n.t(:inbox, :locale => :xx, :count => 1)
    assert_equal '2 messages', I18n.t(:inbox, :locale => :xx, :count => 2)
  end

  test "plain subtrees are not affected by the agreement module" do
    assert_equal({ :leaf => 'a leaf' }, I18n.t(:subtree, :locale => :xx))
  end

  test "hashes with an :agreement key that is not an agreement message are not affected" do
    assert_equal({ :agreement => 'just a string' }, I18n.t(:not_an_agreement_message, :locale => :xx))
  end
end
