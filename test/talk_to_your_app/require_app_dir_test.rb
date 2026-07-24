# frozen_string_literal: true

require "test_helper"
require "fileutils"

# Covers TalkToYourApp.require_app_dir — the loader that backs the
# app/talk_to_your_app/ convention directory (custom_tools/). The loader's job
# is simply to require the files so their side effects run; we observe that by
# checking the constants those files define.
class TalkToYourApp::RequireAppDirTest < TalkToYourApp::TestCase
  # A logger that records the messages it receives, to assert on load failures.
  class RecordingLogger
    attr_reader :errors

    def initialize = @errors = []
    def error(message) = @errors << message
  end

  FIXTURE_SUBDIR = "review_fixture"
  DEFINED_CONSTANTS = %i[ReviewFixtureTool ReviewFixtureOkTool].freeze

  def fixture_dir
    Rails.root.join(TalkToYourApp::APP_DIR, FIXTURE_SUBDIR)
  end

  def teardown
    FileUtils.rm_rf(fixture_dir)
    DEFINED_CONSTANTS.each { |c| Object.send(:remove_const, c) if Object.const_defined?(c, false) }
    super
  end

  def test_loads_files_so_their_side_effects_run
    FileUtils.mkdir_p(fixture_dir)
    # A Tool subclass with a unique name; defining the constant is the side
    # effect we observe.
    File.write(fixture_dir.join("review_fixture_tool.rb"), <<~RUBY)
      class ReviewFixtureTool < TalkToYourApp::Tool
        name "custom.review_fixture"
        def call(_args, _ctx) = json(ok: true)
      end
    RUBY

    TalkToYourApp.require_app_dir(FIXTURE_SUBDIR)
    assert Object.const_defined?(:ReviewFixtureTool, false), "the file's class should be defined after loading"
  end

  def test_is_a_no_op_when_the_subdir_is_absent
    assert_nil TalkToYourApp.require_app_dir("definitely_not_here")
  end

  def test_one_failing_file_is_logged_and_skipped_so_later_files_still_load
    FileUtils.mkdir_p(fixture_dir)
    # Sorts first, and is a *syntax* error (ScriptError, not StandardError) to
    # prove both the per-file isolation and the ScriptError rescue.
    File.write(fixture_dir.join("a_broken.rb"), "def ( oops\n")
    File.write(fixture_dir.join("b_ok.rb"), <<~RUBY)
      class ReviewFixtureOkTool < TalkToYourApp::Tool
        name "custom.review_fixture_ok"
        def call(_args, _ctx) = json(ok: true)
      end
    RUBY

    logger = RecordingLogger.new
    TalkToYourApp.configure { |c| c.logger = logger }

    TalkToYourApp.require_app_dir(FIXTURE_SUBDIR) # must not raise despite a_broken.rb
    assert Object.const_defined?(:ReviewFixtureOkTool, false),
      "the good file must still load after an earlier file fails"
    assert(logger.errors.any? { |m| m.include?("a_broken.rb") },
      "the failing file must be logged")
  end

  def test_falls_back_to_stderr_when_no_logger_configured
    FileUtils.mkdir_p(fixture_dir)
    File.write(fixture_dir.join("boom.rb"), "raise 'kaboom'\n")
    assert_nil TalkToYourApp.configuration.logger, "precondition: no logger set"

    _out, err = capture_io { TalkToYourApp.require_app_dir(FIXTURE_SUBDIR) }
    assert_match(/boom\.rb/, err)
  end
end
