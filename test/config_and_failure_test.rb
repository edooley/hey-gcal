require_relative "test_helper"

class ConfigTest < Minitest::Test
  def with_config(data)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.generate(data))
      yield path
    end
  end

  def dir_of(path) = File.dirname(path)

  def test_init_writes_private_template_once
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sub", "config.json")
      assert HeyGcal::Config.init(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
      refute HeyGcal::Config.init(path)
    end
  end

  def test_template_needs_calendar
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      HeyGcal::Config.init(path)
      error = assert_raises(HeyGcal::Error) { HeyGcal::Config.load(path) }
      assert_equal :config, error.kind
      assert_includes error.message, "calendar_id"
      assert HeyGcal::Config.load(path, require_calendar: false)
    end
  end

  def test_partial_config_gets_defaults
    with_config("name" => "work", "google" => { "calendar_id" => "abc@group.calendar.google.com" }) do |path|
      config = HeyGcal::Config.load(path)
      assert_equal "work", config.name
      assert_equal File.join(dir_of(path), "client_secret.json"), config.client_secret_path
      assert_equal "auto", config.token_store
      assert_equal 90, config.future_days
      assert config.skip_declined?
    end
  end

  def test_rejects_bad_values
    with_config("name" => "../x", "google" => { "calendar_id" => "a" }, "sync" => { "detail" => "all" },
                "healthchecks_url" => "http://hc-ping.com/abc") do |path|
      error = assert_raises(HeyGcal::Error) { HeyGcal::Config.load(path) }
      assert_includes error.message, "name"
      assert_includes error.message, "detail"
      assert_includes error.message, "healthchecks_url"
    end
  end

  def test_title_prefix
    with_config("google" => { "calendar_id" => "a@b" }, "sync" => { "title_prefix" => "E90: " }) do |path|
      assert_equal "E90: ", HeyGcal::Config.load(path).title_prefix
    end
    with_config("google" => { "calendar_id" => "a@b" }, "sync" => { "title_prefix" => 5 }) do |path|
      assert_raises(HeyGcal::Error) { HeyGcal::Config.load(path) }
    end
  end

  def test_stale_after_hours
    with_config("google" => { "calendar_id" => "a@b" }, "stale_after_hours" => 6) do |path|
      assert_equal 21_600, HeyGcal::Config.load(path).stale_after_seconds
    end
    with_config("google" => { "calendar_id" => "a@b" }, "stale_after_hours" => 0) do |path|
      error = assert_raises(HeyGcal::Error) { HeyGcal::Config.load(path) }
      assert_includes error.message, "stale_after_hours"
    end
  end
end

class FailureTest < Minitest::Test
  def test_every_kind_has_actions
    %i[config hey_auth hey_cli google_auth calendar_access secret_store scheduler network circuit_breaker partial meet_mismatch crash].each do |kind|
      explanation = HeyGcal::Failure.explain(HeyGcal::Error.new(kind, "x"))
      refute_empty explanation.title, kind
      refute_empty explanation.actions, kind
    end
  end

  def test_report_lists_deletes_and_steps
    error = HeyGcal::Error.new(:circuit_breaker, "Stopped", details: { deletes: ["\"A\" 2030-01-01 [1]"] })
    report = HeyGcal::Failure.report(error, config: Fixtures.config, consecutive: 2)
    assert_includes report, "Stopped a large delete"
    assert_includes report, "would delete: \"A\" 2030-01-01 [1]"
    assert_includes report, "sync --allow-deletes"
    assert_includes report, "2 runs in a row"
  end

  def test_only_network_is_transient
    assert HeyGcal::Error.new(:network, "x").transient?
    refute HeyGcal::Error.new(:calendar_access, "x").transient?
  end
end
