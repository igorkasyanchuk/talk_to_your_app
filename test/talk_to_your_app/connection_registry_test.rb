# frozen_string_literal: true

require "test_helper"

class TalkToYourApp::ConnectionRegistryTest < TalkToYourApp::TestCase
  Registry = TalkToYourApp::ConnectionRegistry

  def test_declared_connection_is_registered
    TalkToYourApp.configure do |c|
      c.connection :replica_readonly, database: "primary", role: :reading
    end
    assert Registry.registered?(:replica_readonly)
    spec = Registry.fetch(:replica_readonly)
    assert_equal :primary, spec.database
    assert_equal :reading, spec.role
    assert spec.prevent_writes?
  end

  def test_role_defaults_to_reading_when_omitted
    TalkToYourApp.configure { |c| c.connection :read, database: "primary" }
    spec = Registry.fetch(:read)
    assert_equal :reading, spec.role
    assert spec.prevent_writes?, "the default role must prevent writes"
  end

  def test_explicit_writing_role_is_preserved
    TalkToYourApp.configure { |c| c.connection :write, database: "primary", role: :writing }
    spec = Registry.fetch(:write)
    assert_equal :writing, spec.role
    refute spec.prevent_writes?
  end

  def test_replica_true_with_defaulted_role_is_accepted_as_reading
    TalkToYourApp.configure { |c| c.connection :ro, database: "primary", replica: true }
    spec = Registry.fetch(:ro)
    assert_equal :reading, spec.role
    assert spec.replica
  end

  def test_fetch_unregistered_connection_raises_with_actionable_message
    error = assert_raises(TalkToYourApp::ConfigurationError) { Registry.fetch(:nope) }
    assert_match(/:nope is not registered/, error.message)
    assert_match(/config\.connection/, error.message)
  end

  def test_validate_passes_when_required_connection_is_declared
    TalkToYourApp.configure do |c|
      c.connection :replica_readonly, database: "primary", role: :reading
    end
    # Does not raise.
    Registry.validate!([[:replica_readonly, "Plugin :db"]])
  end

  # Covers AE1: a plugin requires a connection that was never declared.
  def test_validate_raises_naming_missing_connection_and_requester
    error = assert_raises(TalkToYourApp::ConfigurationError) do
      Registry.validate!([[:flipper_writer, "Plugin :flipper"]])
    end
    assert_match(/:flipper_writer/, error.message)
    assert_match(/Plugin :flipper/, error.message)
  end

  def test_validate_raises_when_database_key_absent_from_database_yml
    TalkToYourApp.configure do |c|
      c.connection :bogus, database: "nonexistent", role: :reading
    end
    error = assert_raises(TalkToYourApp::ConfigurationError) do
      Registry.validate!([[:bogus, "Plugin :x"]])
    end
    assert_match(/nonexistent/, error.message)
  end

  def test_replica_with_writing_role_is_rejected_at_configure_time
    error = assert_raises(TalkToYourApp::ConfigurationError) do
      TalkToYourApp.configure do |c|
        c.connection :bad, database: "primary", role: :writing, replica: true
      end
    end
    assert_match(/nonsensical/, error.message)
  end

  def test_invalid_role_is_rejected_at_configure_time
    assert_raises(TalkToYourApp::ConfigurationError) do
      TalkToYourApp.configure do |c|
        c.connection :bad, database: "primary", role: :sideways
      end
    end
  end

  def test_reset_drops_pool_classes_and_allows_reconfiguration
    TalkToYourApp.configure { |c| c.connection :ro, database: "primary", role: :reading }
    first = Registry.connection_class_for(Registry.fetch(:ro))
    const_leaf = first.name.split("::").last
    assert Registry.const_defined?(const_leaf, false)

    TalkToYourApp.reset_configuration!

    refute Registry.const_defined?(const_leaf, false), "reset! should drop the generated pool constant"

    TalkToYourApp.configure { |c| c.connection :ro, database: "primary", role: :reading }
    second = Registry.connection_class_for(Registry.fetch(:ro))
    refute_equal first.object_id, second.object_id, "a fresh pool class should be built after reset!"
  end

  def test_with_switches_to_declared_role
    TalkToYourApp.configure do |c|
      c.connection :ro, database: "primary", role: :reading
    end
    observed_role = nil
    result = Registry.with(:ro) do |conn|
      observed_role = conn.role if conn.respond_to?(:role)
      conn.select_value("SELECT 1")
    end
    assert_equal 1, result
    assert_equal :reading, observed_role if observed_role
  end

  # Captures the kwargs `with` forwards to `connected_to` for a given connection.
  # Asserting the arguments (not the runtime effect) makes this a deterministic,
  # version-independent guard: Rails' write-prevention state is global/thread-
  # local and adapter/version specific (SQLite only enforces it on raw SQL from
  # 8.0+), so observing `preventing_writes?` is flaky across the matrix. The real
  # end-to-end write boundary is the database role, covered by the Postgres
  # query tests.
  def connected_to_kwargs_for(conn_name)
    klass = Registry.connection_class_for(Registry.fetch(conn_name))
    captured = nil
    klass.stub(:connected_to, ->(**kwargs) { captured = kwargs }) do
      Registry.with(conn_name) { |_conn| :noop }
    end
    captured
  end

  # Security regression guard for `with` passing `prevent_writes:` explicitly.
  # A :reading connection must switch to the reading role AND request write
  # prevention, so the read-only contract does not depend on framework
  # defaulting. If the explicit `prevent_writes: spec.prevent_writes?` were
  # dropped this assertion fails.
  def test_with_forwards_reading_role_and_prevents_writes
    TalkToYourApp.configure { |c| c.connection :ro, database: "primary", role: :reading }
    kwargs = connected_to_kwargs_for(:ro)
    assert_equal :reading, kwargs[:role]
    assert_equal true, kwargs[:prevent_writes], "a :reading connection must request prevent_writes"
  end

  # The opt-in write path: a :writing connection must switch to the writing role
  # and NOT prevent writes, so the deliberate `role: :writing` wiring works.
  # Guards against a regression that forces prevent_writes on for every
  # connection (which would silently break the documented writable-DB opt-in).
  def test_with_forwards_writing_role_and_allows_writes
    TalkToYourApp.configure { |c| c.connection :writer, database: "primary", role: :writing }
    kwargs = connected_to_kwargs_for(:writer)
    assert_equal :writing, kwargs[:role]
    assert_equal false, kwargs[:prevent_writes], "a :writing connection must not prevent writes"
  end

  # `with` wraps the yield in `with_connection`, which must check the connection
  # back into the pool when the block ends. A leak here would exhaust the pool
  # under load (a DoS-class regression), so assert no connection stays leased to
  # the current thread after the block returns.
  def test_with_returns_connection_to_the_pool
    TalkToYourApp.configure { |c| c.connection :ro, database: "primary", role: :reading }
    klass = Registry.connection_class_for(Registry.fetch(:ro))
    Registry.with(:ro) { |conn| conn.select_value("SELECT 1") }
    # Resolve the pool under the same role `with` used; the abstract class only
    # defines the :reading pool.
    leased = klass.connected_to(role: :reading) { klass.connection_pool.active_connection? }
    refute leased,
      "with must check the leased connection back into the pool when the block ends"
  end
end
