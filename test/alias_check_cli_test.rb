# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require 'open3'

class AliasCheckCliTest < Minitest::Test
  CLI = File.expand_path('../bin/i18n-alias-check', __dir__)

  def run_cli(*args)
    Open3.capture2e(RbConfig.ruby, CLI, *args)
  end

  def fixture(name)
    File.join(File.dirname(__FILE__), 'test_data', 'alias_check', name)
  end

  def test_reports_cross_backend_cycle_and_exits_nonzero
    out, status = run_cli(
      '--backend', fixture('cross_backend_cycle/app_backend'),
      '--backend', fixture('cross_backend_cycle/gem_backend'),
      '--fallback-default', 'none')
    refute status.success?
    assert_match(/CIRCULAR ALIASES/, out)
    assert_match(/marketing\.offer -> promo\.banner -> marketing\.offer/, out)
    assert_match(/app_backend.*en\.yml/m, out)
    assert_match(/gem_backend.*en\.yml/m, out)
    assert_match(/DANGLING ALIASES/, out)
  end

  def test_healthy_tree_exits_zero
    out, status = run_cli(
      '--backend', fixture('healthy'), '--fallback-default', 'none')
    assert status.success?, out
    assert_match(/No alias problems found/, out)
  end

  def test_json_output_is_parseable_and_flags_cycle
    out, status = run_cli(
      '--backend', fixture('cross_backend_cycle/app_backend'),
      '--backend', fixture('cross_backend_cycle/gem_backend'),
      '--fallback-default', 'none', '--json')
    refute status.success?
    require 'json'
    data = JSON.parse(out)
    assert_equal 1, data['summary']['cycle']
    assert_equal 1, data['summary']['dangling']
    files = data['cycles'].flat_map { |c| c['entries'].flat_map { |e|
      e['hops'].map { |h| h['file'] } } }.compact
    assert files.any? { |f| f.include?('app_backend') }
    assert files.any? { |f| f.include?('gem_backend') }
  end

  def test_missing_directory_is_usage_error
    _out, status = run_cli('--backend', File.join(Dir.tmpdir, 'nope-nope-nope'))
    assert_equal 2, status.exitstatus
  end

  def test_no_backend_is_usage_error
    _out, status = run_cli
    assert_equal 2, status.exitstatus
  end

  def test_broken_yaml_is_reported_as_load_error
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'bad.yml'), "en:\n  - :x\n  bad: [")
      out, status = run_cli('--backend', dir, '--fallback-default', 'none')
      refute status.success?
      assert_match(/FILE LOAD ERRORS|load_errors/, out)
    end
  end

  def test_does_not_invoke_procs
    # rb_backend/en.rb contains a lambda; running the checker over it must
    # never execute that lambda (the tool is static). The dynamic alias is
    # reported instead and the run still exits 0 for that directory.
    out, status = run_cli('--backend', fixture('rb_backend'),
                          '--fallback-default', 'none')
    assert status.success?, out
    assert_match(/DYNAMIC TARGETS/, out)
  end
end
