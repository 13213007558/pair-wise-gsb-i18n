# frozen_string_literal: true

require 'test_helper'
require 'date'

class I18nLocalizeIntervalTest < I18n::TestCase
  def setup
    super
    I18n.backend = I18n::Backend::Simple.new
  end

  test "localize_interval returns complete endpoints for a literal format without a table" do
    start_date = ::Date.new(2026, 10, 1)
    end_date = ::Date.new(2026, 10, 3)

    assert_equal "2026-10-01–2026-10-03", I18n.localize_interval(start_date, end_date, :format => "%Y-%m-%d")
  end

  test "localize_interval accepts a range and format argument" do
    interval = ::Date.new(2026, 10, 1)..::Date.new(2026, 10, 3)

    assert_equal "2026-10-01–2026-10-03", I18n.localize_interval(interval, :format => "%Y-%m-%d")
  end

  test "localize_interval validates both endpoints" do
    assert_raises(I18n::ArgumentError) do
      I18n.localize_interval(::Date.new(2026, 10, 1), nil)
    end
  end

  test "localize_interval returns the default when both endpoints are nil" do
    assert_equal "none", I18n.localize_interval(nil, nil, :default => "none")
  end
end
