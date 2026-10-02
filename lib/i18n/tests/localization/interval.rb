# frozen_string_literal: true

module I18n
  module Tests
    module Localization
      module Interval
        def setup
          super
          setup_interval_translations
        end

        test "localize interval: uses the day pattern for an interval on the same day" do
          start_date = ::Date.new(2026, 10, 1)
          end_date = ::Date.new(2026, 10, 3)

          assert_equal "2026年10月1—3日", I18n.localize_interval(start_date, end_date, :locale => :iv)
        end

        test "localize interval: uses the month pattern across months" do
          start_date = ::Date.new(2026, 9, 28)
          end_date = ::Date.new(2026, 10, 3)

          assert_equal "2026年9月28日—10月3日", I18n.localize_interval(start_date, end_date, :locale => :iv)
        end

        test "localize interval: uses the year pattern across years" do
          start_date = ::Date.new(2025, 12, 30)
          end_date = ::Date.new(2026, 1, 2)

          assert_equal "2025年12月30日—2026年1月2日", I18n.localize_interval(start_date, end_date, :locale => :iv)
        end

        test "localize interval: uses the hour pattern when the meridian changes" do
          start_time = ::Time.utc(2026, 10, 1, 3)
          end_time = ::Time.utc(2026, 10, 1, 15)

          assert_equal "2026年10月1日 3上午—3下午", I18n.localize_interval(start_time, end_time, :locale => :iv)
        end

        test "localize interval: detects a meridian difference when 12-hour hour numbers match" do
          start_time = ::Time.utc(2026, 10, 1, 0)
          end_time = ::Time.utc(2026, 10, 1, 12)

          assert_equal "2026年10月1日 12上午—12下午", I18n.localize_interval(start_time, end_time, :locale => :iv)
        end

        test "localize interval: returns the source and shared fragments when requested" do
          start_time = ::Time.utc(2026, 10, 1, 3)
          end_time = ::Time.utc(2026, 10, 1, 15)

          result = I18n.localize_interval(start_time, end_time, :locale => :iv, :parts => true)

          assert_equal "2026年10月1日 3上午—3下午", result.to_s
          assert_equal "3上午", result.start
          assert_equal "3下午", result.end
          assert_equal "2026年10月1日 ", result.shared
          assert_equal [
            { :source => :shared, :value => "2026年10月1日 " },
            { :source => :start, :value => "3上午" },
            { :source => :end, :value => "3下午" }
          ], result.parts
        end

        test "localize interval: returns complete endpoints when a granularity pattern is missing" do
          start_date = ::Date.new(2025, 12, 30)
          end_date = ::Date.new(2026, 1, 2)

          result = I18n.localize_interval(start_date, end_date, :format => :short, :locale => :iv, :parts => true)

          assert_equal "25/12/30—26/01/02", result.to_s
          assert_equal "25/12/30", result.start
          assert_equal "26/01/02", result.end
          assert_nil result.shared
        end

        test "localize interval: uses the same pattern for identical endpoints" do
          date = ::Date.new(2026, 10, 1)

          assert_equal "2026年10月1日", I18n.localize_interval(date, date, :locale => :iv)
        end

        test "localize interval: accepts an array pattern with explicit endpoint formats" do
          start_date = ::Date.new(2026, 10, 1)
          end_date = ::Date.new(2026, 10, 3)

          assert_equal "10/01—10/03", I18n.localize_interval(start_date, end_date, :format => :array, :locale => :iv)
        end

        test "localize interval: accepts a range and compares wall fields in the given time zone" do
          start_time = ::Time.utc(2026, 10, 1, 14)
          end_time = ::Time.utc(2026, 10, 1, 15)
          interval = start_time..end_time

          assert_equal "2026年10月1日—10月2日", I18n.localize_interval(interval, :locale => :iv, :time_zone => "+09:00")
          assert_equal "2026年10月1日—10月2日", I18n.localize_interval(interval, :locale => :iv, :zone => "+09:00")
        end

        test "localize interval: accepts a duck typed named time zone" do
          time_zone = Object.new
          def time_zone.utc_to_local(time)
            time.getlocal("+09:00")
          end
          interval = ::Time.utc(2026, 10, 1, 14)..::Time.utc(2026, 10, 1, 15)

          assert_equal "2026年10月1日—10月2日", I18n.localize_interval(interval, :locale => :iv, :time_zone => time_zone)
        end

        test "localize interval: keeps offsets when a fall back makes wall fields identical" do
          start_time = ::Time.new(2025, 11, 2, 1, 30, 0, "-04:00")
          end_time = ::Time.new(2025, 11, 2, 1, 30, 0, "-05:00")

          result = I18n.localize_interval(start_time, end_time, :locale => :iv, :parts => true)

          assert_equal "2025年11月2日 1:30 -0400—1:30 -0500", result.to_s
          assert_equal "1:30 -0400", result.start
          assert_equal "1:30 -0500", result.end
          assert_equal "2025年11月2日 ", result.shared
        end

        test "localize interval: keeps offsets in complete endpoint fallback when no zone pattern exists" do
          start_time = ::Time.new(2025, 11, 2, 1, 30, 0, "-04:00")
          end_time = ::Time.new(2025, 11, 2, 1, 30, 0, "-05:00")

          result = I18n.localize_interval(start_time, end_time, :format => :short, :locale => :iv)

          assert_equal "1:30 -0400—1:30 -0500", result
        end

        protected

          def setup_interval_translations
            I18n.backend.store_translations :iv, {
              :date => {
                :formats => {
                  :default => "%Y年%-m月%-d日",
                  :short => "%y/%m/%d"
                },
                :intervals => {
                  :formats => {
                    :default => {
                      :same => "%{start:%Y年%-m月%-d日}",
                      :day => "%{shared:%Y年%-m月}%{start:%-d}—%{end:%-d日}",
                      :month => "%{start:%Y年%-m月%-d日}—%{end:%-m月%-d日}",
                      :year => "%{start:%Y年%-m月%-d日}—%{end:%Y年%-m月%-d日}"
                    },
                    :short => {
                      :day => "%{start:%y/%m/%d}—%{end:%m/%d}"
                    },
                    :array => {
                      :day => ["%m/%d", "%m/%d"]
                    }
                  }
                }
              },
              :time => {
                :formats => {
                  :default => "%Y年%-m月%-d日 %-H:%M",
                  :short => "%-H:%M"
                },
                :intervals => {
                  :formats => {
                    :default => {
                      :same => "%{start:%Y年%-m月%-d日 %-H:%M}",
                      :meridian => "%{shared:%Y年%-m月%-d日 }%{start:%-l%P}—%{end:%-l%P}",
                      :hour => "%{shared:%Y年%-m月%-d日 }%{start:%-l%P}—%{end:%-l%P}",
                      :day => "%{start:%Y年%-m月%-d日}—%{end:%-m月%-d日}",
                      :month => "%{start:%Y年%-m月%-d日}—%{end:%-m月%-d日}",
                      :year => "%{start:%Y年%-m月%-d日}—%{end:%Y年%-m月%-d日}",
                      :zone => "%{shared:%Y年%-m月%-d日 }%{start:%-l:%M}%{shared:—}%{end:%-l:%M}"
                    }
                  }
                },
                :am => "上午",
                :pm => "下午"
              },
              :support => { :interval => { :default => "—" } }
            }
          end
      end
    end
  end
end
