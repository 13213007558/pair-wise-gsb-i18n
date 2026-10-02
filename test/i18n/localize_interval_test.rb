# frozen_string_literal: true

require 'test_helper'

class I18nLocalizeIntervalTest < I18n::TestCase
  def setup
    I18n.backend = I18n::Backend::Simple.new
    super
    store_translations(:en,
      :date => {
        :formats => {
          :default => '%Y年%-m月%-d日',
        },
        :interval_formats => {
          :default => {
            :year => '%Y年%-m月%-d日 – %Y年%-m月%-d日',
            :month => '%Y年%-m月%-d日 – %-m月%-d日',
            :day => '%Y年%-m月%-d日 – %-d日',
          },
        },
      },
      :time => {
        :formats => {
          :default => '%Y年%-m月%-d日 %-I:%M%p %z',
          :short => '%Y年%-m月%-d日 %-I:%M%p %z',
          :date_only => '%Y年%-m月%-d日 %-I:%M%p',
        },
        :interval_formats => {
          :default => {
            :hour => '%Y年%-m月%-d日 %-I:%M%p %z – %-I:%M%p %z',
            :minute => '%Y年%-m月%-d日 %-I:%M%p %z – %-I:%M%p %z',
            :offset => '%Y年%-m月%-d日 %-I:%M%p %z – %-I:%M%p %z',
          },
        },
        :am => '上午',
        :pm => '下午',
      }
    )
  end

  test 'localize interval compresses a same-month range' do
    first = Date.new(2026, 10, 1)
    last = Date.new(2026, 10, 3)

    assert_equal '2026年10月1日 – 3日', I18n.localize_interval(first, last)
    assert_equal '2026年10月1日 – 3日', I18n.localize_interval(first..last)
  end

  test 'localize interval uses the month pattern when the month differs' do
    first = Date.new(2026, 10, 30)
    last = Date.new(2026, 11, 2)

    assert_equal '2026年10月30日 – 11月2日', I18n.localize_interval(first, last)
  end

  test 'localize interval uses the year pattern when the year differs' do
    first = Date.new(2026, 12, 31)
    last = Date.new(2027, 1, 1)

    assert_equal '2026年12月31日 – 2027年1月1日', I18n.localize_interval(first, last)
  end

  test 'localize interval distinguishes morning from afternoon' do
    first = Time.new(2026, 10, 1, 10, 30, 0, '+08:00')
    last = Time.new(2026, 10, 1, 14, 30, 0, '+08:00')

    assert_equal '2026年10月1日 10:30上午 +0800 – 2:30下午 +0800',
      I18n.localize_interval(first, last)
  end

  test 'localize interval returns shared, start, and end fragments' do
    first = Date.new(2026, 10, 1)
    last = Date.new(2026, 10, 3)

    fragments = I18n.localize_interval(first, last, :fragments => true)

    assert_equal(
      {
        :string => '2026年10月1日 – 3日',
        :fragments => [
          { :source => :shared, :value => '2026年10月' },
          { :source => :start, :value => '1日' },
          { :source => :shared, :value => ' – ' },
          { :source => :end, :value => '3日' },
        ],
      },
      fragments
    )
    assert_equal fragments, I18n.localize_interval(first, last, :parts => true)
  end

  test 'localize interval uses the specified offset for DateTimes' do
    first = DateTime.new(2026, 10, 1, 15, 0)
    last = DateTime.new(2026, 10, 1, 17, 0)

    assert_equal '2026年10月1日 11:00下午 +0800 – 2026年10月2日 1:00上午 +0800',
      I18n.localize_interval(first, last, :time_zone => '+08:00')
  end

  test 'localize interval rejects a pattern that omits a differing field' do
    first = Time.new(2026, 10, 1, 10, 0, 0, '+08:00')
    last = Time.new(2026, 10, 1, 10, 30, 0, '+08:00')
    unsafe_pattern = '%Y年%-m月%-d日 %-I:00%p – %-I:00%p'

    assert_equal '2026年10月1日 10:00上午 +0800 – 2026年10月1日 10:30上午 +0800',
      I18n.localize_interval(first, last, :format => unsafe_pattern)
  end

  test 'localize interval falls back to complete endpoints when a pattern is missing' do
    first = Time.new(2026, 10, 1, 10, 0, 0, '+08:00')
    last = Time.new(2026, 10, 1, 10, 30, 0, '+08:00')

    assert_equal '2026年10月1日 10:00上午 +0800 – 2026年10月1日 10:30上午 +0800',
      I18n.localize_interval(first, last, :format => :short)
  end

  test 'localize interval fallback retains offsets when the default format omits them' do
    first = Time.new(2026, 11, 1, 1, 30, 0, '-04:00')
    last = Time.new(2026, 11, 1, 1, 30, 0, '-05:00')

    assert_equal '2026年11月1日 1:30上午 -0400 – 2026年11月1日 1:30上午 -0500',
      I18n.localize_interval(first, last, :format => :date_only)
  end

  test 'localize interval compares fields in the specified time zone' do
    first = Time.utc(2026, 10, 1, 15, 0)
    last = Time.utc(2026, 10, 1, 17, 0)

    result = I18n.localize_interval(first, last, :time_zone => '+08:00')

    assert_equal '2026年10月1日 11:00下午 +0800 – 2026年10月2日 1:00上午 +0800', result
  end

  test 'localize interval retains offsets for identical fall-back wall times' do
    first = Time.new(2026, 11, 1, 1, 30, 0, '-04:00')
    last = Time.new(2026, 11, 1, 1, 30, 0, '-05:00')

    assert_equal '2026年11月1日 1:30上午 -0400 – 1:30上午 -0500',
      I18n.localize_interval(first, last)
  end

  test 'localize interval accepts a utc_to_local time-zone object' do
    first = Time.utc(2026, 10, 1, 15)
    last = Time.utc(2026, 10, 1, 17)
    time_zone = Object.new
    def time_zone.utc_to_local(time)
      time.getlocal('+08:00')
    end

    assert_equal '2026年10月1日 11:00下午 +0800 – 2026年10月2日 1:00上午 +0800',
      I18n.localize_interval(first, last, :time_zone => time_zone)
  end
end
