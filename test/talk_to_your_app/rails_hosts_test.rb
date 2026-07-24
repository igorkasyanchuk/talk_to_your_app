# frozen_string_literal: true

require "test_helper"
require "ipaddr"

# Covers TalkToYourApp.rails_hosts: derives a literal Host allowlist from the
# host app's Rails.application.config.hosts, keeping only plain host strings
# (the transport matches hosts literally, so regexp/IPAddr/dotted-wildcard
# entries can't be forwarded).
class RailsHostsTest < TalkToYourApp::TestCase
  def with_rails_hosts(hosts)
    original = Rails.application.config.hosts
    Rails.application.config.hosts = hosts
    yield
  ensure
    Rails.application.config.hosts = original
  end

  def test_keeps_plain_host_strings
    with_rails_hosts(["app.example.com", "admin.example.com"]) do
      assert_equal ["app.example.com", "admin.example.com"], TalkToYourApp.rails_hosts
    end
  end

  def test_drops_regexp_ipaddr_and_dotted_wildcard_entries
    with_rails_hosts([/.*\.example\.com/, IPAddr.new("10.0.0.0/8"), ".example.com", "app.example.com"]) do
      assert_equal ["app.example.com"], TalkToYourApp.rails_hosts
    end
  end

  def test_empty_when_no_string_hosts
    with_rails_hosts([]) do
      assert_equal [], TalkToYourApp.rails_hosts
    end
  end
end
