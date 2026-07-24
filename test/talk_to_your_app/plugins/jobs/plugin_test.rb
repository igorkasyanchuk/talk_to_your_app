# frozen_string_literal: true

require "test_helper"

class TalkToYourApp::Plugins::Jobs::PluginTest < TalkToYourApp::TestCase
  Jobs = TalkToYourApp::Plugins::Jobs

  # A stub adapter standing in for a real Sidekiq/Solid Queue adapter.
  class StubAdapter
    def self.required_gem = nil
    def self.queue_sizes = { "default" => 3 }
    def self.recent_jobs(limit:) = [{ jid: "1", class: "Foo", limit: limit }]
    def self.failed_jobs(limit:) = [{ jid: "2", error_message: "boom", limit: limit }]
    def self.rate_metrics(window:) = { window_seconds: window, processed: 5 }
  end

  def setup
    super
    Jobs.register_adapter(:stub, StubAdapter)
    @tools = Jobs.build_tools(:stub) # 4 subclasses named "stub.*", bound to :stub
  end

  def tool(suffix)
    @tools.find { |t| t.tool_name == "stub.#{suffix}" }
  end

  def body_of(response)
    JSON.parse(response.content.first[:text])
  end

  def test_build_tools_namespaces_names_per_adapter
    assert_equal ["stub.failed_jobs", "stub.queue_sizes", "stub.rate_metrics", "stub.recent_jobs"],
      @tools.map(&:tool_name).sort
  end

  def test_tools_delegate_to_the_bound_adapter
    assert_equal({ "default" => 3 }, body_of(tool("queue_sizes").new.call({}, nil)))
  end

  def test_subclass_inherits_the_argument_dsl
    # RecentJobs declares a :limit argument; the generated subclass inherits it.
    result = body_of(tool("recent_jobs").new.call({ limit: 1000 }, nil))
    assert_equal 500, result.first["limit"], "limit must clamp to the inherited MAX_LIMIT"
  end

  def test_recent_jobs_defaults_limit_to_50_through_dispatch
    result = body_of(tool("recent_jobs").to_mcp_tool.call(server_context: nil))
    assert_equal 50, result.first["limit"]
  end

  def test_rate_metrics_defaults_window_to_30_minutes
    result = body_of(tool("rate_metrics").to_mcp_tool.call(server_context: nil))
    assert_equal 1800, result["window_seconds"]
  end

  def test_validate_adapter_raises_for_an_unknown_adapter
    error = assert_raises(TalkToYourApp::ConfigurationError) { Jobs.validate_adapter!(:goodjob) }
    assert_match(/goodjob/, error.message)
    assert_match(/available/i, error.message)
  end

  # The two real adapter plugins expose adapter-namespaced tools, so both can be
  # enabled at once without a tool-name collision.
  def test_sidekiq_plugin_tools_are_namespaced
    assert_equal ["sidekiq.failed_jobs", "sidekiq.queue_sizes", "sidekiq.rate_metrics", "sidekiq.recent_jobs"],
      Jobs::SidekiqPlugin.tools.map(&:tool_name).sort
  end

  def test_solid_queue_plugin_tools_are_namespaced
    assert_equal ["solid_queue.failed_jobs", "solid_queue.queue_sizes", "solid_queue.rate_metrics", "solid_queue.recent_jobs"],
      Jobs::SolidQueuePlugin.tools.map(&:tool_name).sort
  end

  def test_both_plugins_expose_eight_distinct_tool_names
    names = (Jobs::SidekiqPlugin.tools + Jobs::SolidQueuePlugin.tools).map(&:tool_name)
    assert_equal 8, names.uniq.size, "sidekiq + solid_queue must expose 8 non-colliding tool names"
  end
end
