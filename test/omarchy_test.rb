require_relative "test_helper"

class OmarchyTest < Minitest::Test
  O = HeyGcal::Omarchy
  NOW = Time.utc(2030, 1, 10, 12, 0, 0)

  def setup
    @dir = Dir.mktmpdir
    dir = @dir
    O.singleton_class.alias_method(:real_shell_config_path, :shell_config_path)
    O.singleton_class.alias_method(:real_omarchy_path, :omarchy_path)
    O.define_singleton_method(:shell_config_path) { File.join(dir, "config", "omarchy", "shell.json") }
    O.define_singleton_method(:omarchy_path) { File.join(dir, "omarchy") }
    FileUtils.mkdir_p(File.join(@dir, "omarchy", "config", "omarchy"))
    File.write(File.join(@dir, "omarchy", "config", "omarchy", "shell.json"), JSON.generate(
      "version" => 1,
      "bar" => { "layout" => { "left" => [{ "id" => "omarchy.workspaces" }], "center" => [{ "id" => "omarchy.clock" }], "right" => [{ "id" => "omarchy.tray" }] } }
    ))
    @config = Fixtures.config
  end

  def teardown
    O.singleton_class.alias_method(:shell_config_path, :real_shell_config_path)
    O.singleton_class.alias_method(:omarchy_path, :real_omarchy_path)
    FileUtils.rm_rf(@dir)
  end

  def shell_json
    JSON.parse(File.read(O.shell_config_path))
  end

  def json(state)
    JSON.parse(O.bar_json(state, @config, now: NOW))
  end

  def test_bar_json_healthy
    out = json("last_success_at" => (NOW - 120).iso8601, "last_summary" => "+1 ~0 -0")
    assert_equal O::GLYPH_OK, out["text"]
    assert_equal "", out["class"]
    assert_includes out["tooltip"], "synced 2 min ago"
  end

  def test_bar_json_failure_is_highlighted
    out = json("failure" => { "title" => "HEY CLI is signed out" }, "last_success_at" => (NOW - 120).iso8601)
    assert_equal O::GLYPH_ALERT, out["text"]
    assert_equal "active", out["class"]
    assert_includes out["tooltip"], "HEY CLI is signed out"
  end

  def test_bar_json_stale
    out = json("last_success_at" => (NOW - 3 * 86_400).iso8601)
    assert_equal "active", out["class"]
    assert_includes out["tooltip"], "no sync for 3 days"
  end

  def test_bar_json_stale_threshold_is_configurable
    config = Fixtures.config("stale_after_hours" => 4)
    out = JSON.parse(O.bar_json({ "last_success_at" => (NOW - 5 * 3600).iso8601 }, config, now: NOW))
    assert_equal "active", out["class"]
    assert_includes out["tooltip"], "no sync for 5 h"
    out = JSON.parse(O.bar_json({ "last_success_at" => (NOW - 3 * 3600).iso8601 }, config, now: NOW))
    assert_equal "", out["class"]
  end

  def test_bar_json_never_run
    assert_includes json({})["tooltip"], "not synced yet"
  end

  def test_add_starts_from_omarchy_defaults
    O.add_bar_module(@config)
    data = shell_json
    assert_equal [{ "id" => "omarchy.workspaces" }], data["bar"]["layout"]["left"]
    assert_equal "omarchy.clock", data["bar"]["layout"]["center"].first["id"]
    right = data["bar"]["layout"]["right"]
    assert_equal %w[hey-gcal omarchy.tray], right.map { |e| e["id"] }
    assert_equal "command", right.first["type"]
    assert_equal 30, right.first["interval"]
  end

  def test_add_keeps_user_layout_and_is_idempotent
    FileUtils.mkdir_p(File.dirname(O.shell_config_path))
    File.write(O.shell_config_path, JSON.generate("version" => 1, "theme" => "x", "bar" => { "layout" => { "left" => [{ "id" => "hey-gcal", "type" => "command", "exec" => "old" }] } }))
    O.add_bar_module(@config)
    O.add_bar_module(@config)
    data = shell_json
    assert_equal "x", data["theme"]
    assert_equal 1, data["bar"]["layout"].values.flatten.count { |e| e["id"] == "hey-gcal" }
    assert_includes data["bar"]["layout"]["left"].first["exec"], " bar --config "
    assert File.exist?("#{O.shell_config_path}.hey-gcal.bak")
  end

  def test_remove
    O.add_bar_module(@config)
    assert O.bar_module?(@config)
    O.remove_bar_module(@config)
    refute O.bar_module?(@config)
    assert_equal ["omarchy.tray"], shell_json["bar"]["layout"]["right"].map { |e| e["id"] }
  end

  def test_entry_commands_are_shell_safe
    config = HeyGcal::Config.new("/home/a b/.config/hey-gcal/work.json", Fixtures.config.data.merge("name" => "work"))
    entry = O.bar_entry(config)
    assert_equal "hey-gcal-work", entry["id"]
    assert_includes entry["exec"], "/home/a\\ b/.config/hey-gcal/work.json"
    assert entry["onClick"].start_with?("omarchy-launch-tui --app-id\\=org.omarchy.hey-gcal ") || entry["onClick"].start_with?("omarchy-launch-tui --app-id=org.omarchy.hey-gcal ")
    assert_includes entry["onClick"], "status --wait"
    assert_includes entry["onRightClick"], " sync --config "
  end
end
