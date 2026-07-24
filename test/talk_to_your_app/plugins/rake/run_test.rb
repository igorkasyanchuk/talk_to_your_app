# frozen_string_literal: true

require "test_helper"
require "stringio"

class TalkToYourApp::Plugins::Rake::RunTest < TalkToYourApp::TestCase
  Rake = TalkToYourApp::Plugins::Rake
  Run = Rake::Tools::Run

  def enable(allowed)
    TalkToYourApp.configure do |c|
      c.api_keys = { "k" => "secret" }
      c.plugin :rake, connection: false, allowed: allowed
    end
  end

  def call(args)
    JSON.parse(Run.new.call(args, nil).content.first[:text])
  end

  def test_boot_fails_without_an_allowed_list
    TalkToYourApp.configure { |c| c.api_keys = { "k" => "x" }; c.plugin :rake, connection: false }
    error = assert_raises(TalkToYourApp::ConfigurationError) { TalkToYourApp::Railtie.validate_boot! }
    assert_match(/allowed/, error.message)
  end

  def test_boot_passes_with_allowed_list
    enable(["stats"])
    TalkToYourApp::Railtie.validate_boot! # does not raise
  end

  def test_disallowed_task_is_refused_without_running
    enable(["stats"])
    ran = false
    Run.stub(:run_task, ->(*) { ran = true; Run::Result.new(stdout: "", stderr: "", exit_code: 0) }) do
      response = Run.new.call({ task: "db:drop" }, nil)
      assert response.error?
      assert_match(/not allowed/, response.content.first[:text])
    end
    refute ran, "a disallowed task must never execute"
  end

  def test_allowed_task_returns_status_and_output
    enable(["stats"])
    Run.stub(:run_task, ->(task, args) { Run::Result.new(stdout: "users=2\n", stderr: "", exit_code: 0) }) do
      result = call({ task: "stats" })
      assert_equal "stats", result["task"]
      assert_equal "success", result["status"]
      assert_equal 0, result["exit_code"]
      assert_equal "users=2", result["output"]
      assert_nil result["error"]
    end
  end

  def test_nonzero_exit_is_reported_as_error
    enable(["stats"])
    Run.stub(:run_task, ->(*) { Run::Result.new(stdout: "", stderr: "boom", exit_code: 1) }) do
      result = call({ task: "stats" })
      assert_equal "error", result["status"]
      assert_equal 1, result["exit_code"]
      assert_equal "boom", result["error"]
    end
  end

  def test_args_are_forwarded_to_the_task_invocation
    enable(["echo"])
    seen = nil
    Run.stub(:run_task, ->(task, args) { seen = [task, args]; Run::Result.new(stdout: "Hello, Ada!", stderr: "", exit_code: 0) }) do
      call({ task: "echo", args: ["Ada"] })
    end
    assert_equal ["echo", ["Ada"]], seen
  end

  def test_timeout_defaults_to_20_seconds
    enable(["stats"])
    assert_equal 20, Rake.timeout
  end

  def test_timeout_is_configurable
    TalkToYourApp.configure do |c|
      c.api_keys = { "k" => "secret" }
      c.plugin :rake, connection: false, allowed: ["stats"], timeout: 60
    end
    assert_equal 60, Rake.timeout
  end

  def test_timeout_falls_back_to_default_for_non_positive_or_non_numeric
    [0, -5, "fast"].each do |bad|
      TalkToYourApp.reset_configuration!
      TalkToYourApp.configure do |c|
        c.api_keys = { "k" => "secret" }
        c.plugin :rake, connection: false, allowed: ["stats"], timeout: bad
      end
      assert_equal 20, Rake.timeout, "timeout: #{bad.inspect} must fall back to the default, not 0"
    end
  end

  def test_read_capped_passes_small_output_through
    assert_equal "hello", Run.read_capped(StringIO.new("hello"))
  end

  def test_read_capped_truncates_oversized_output
    out = Run.read_capped(StringIO.new("x" * (Run::MAX_OUTPUT_BYTES + 5_000)))
    assert_operator out.bytesize, :<=, Run::MAX_OUTPUT_BYTES + 100
    assert_match(/output truncated/, out)
  end

  def test_timeout_surfaces_as_a_tool_error
    enable(["stats"])
    Run.stub(:run_task, ->(*) { raise Timeout::Error, "rake task \"stats\" exceeded the 20s timeout and was terminated" }) do
      response = Run.new.call({ task: "stats" }, nil)
      assert response.error?
      assert_match(/exceeded the 20s timeout/, response.content.first[:text])
    end
  end

  def test_run_task_builds_bracketed_invocation_for_args
    # The pure invocation string used for `bundle exec rake <invocation>`.
    invocation = ->(task, args) { args.empty? ? task : "#{task}[#{args.join(",")}]" }
    assert_equal "echo", invocation.call("echo", [])
    assert_equal "echo[Ada,42]", invocation.call("echo", ["Ada", "42"])
  end
end
