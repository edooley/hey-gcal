require_relative "test_helper"

# Exercises every OS's code paths on whichever OS runs the tests, by stubbing
# Platform.os and the environment.
module PlatformStubs
  def with_os(os, env = {})
    saved_env = env.keys.to_h { |k| [k, ENV[k]] }
    env.each { |k, v| ENV[k] = v }
    HeyGcal::Platform.singleton_class.alias_method(:real_os, :os)
    HeyGcal::Platform.define_singleton_method(:os) { os }
    yield
  ensure
    HeyGcal::Platform.singleton_class.alias_method(:os, :real_os)
    saved_env.each { |k, v| ENV[k] = v }
  end
end

class PlatformTest < Minitest::Test
  include PlatformStubs

  def test_windows_dirs
    with_os(:windows, "APPDATA" => "/w/Roaming", "LOCALAPPDATA" => "/w/Local") do
      assert_equal File.expand_path("/w/Roaming/hey-gcal"), HeyGcal::Platform.config_dir
      assert_equal File.expand_path("/w/Local/hey-gcal/state"), HeyGcal::Platform.state_dir
      assert_equal File.expand_path("/w/Local/hey-gcal/logs"), HeyGcal::Platform.log_dir
    end
  end

  def test_linux_dirs_follow_xdg
    with_os(:linux, "XDG_CONFIG_HOME" => "/x/config", "XDG_STATE_HOME" => "/x/state") do
      assert_equal File.expand_path("/x/config/hey-gcal"), HeyGcal::Platform.config_dir
      assert_equal File.expand_path("/x/state/hey-gcal"), HeyGcal::Platform.state_dir
      assert_equal HeyGcal::Platform.state_dir, HeyGcal::Platform.log_dir
    end
  end

  def test_linux_dirs_default
    with_os(:linux, "XDG_CONFIG_HOME" => nil, "XDG_STATE_HOME" => nil) do
      assert_equal File.expand_path("~/.config/hey-gcal"), HeyGcal::Platform.config_dir
      assert_equal File.expand_path("~/.local/state/hey-gcal"), HeyGcal::Platform.state_dir
    end
  end

  def test_macos_logs
    with_os(:macos) do
      assert_equal File.expand_path("~/Library/Logs/hey-gcal"), HeyGcal::Platform.log_dir
    end
  end

  def test_which_finds_executables
    Dir.mktmpdir do |dir|
      exe = File.join(dir, "fakebin")
      File.write(exe, "#!/bin/sh\n")
      File.chmod(0o755, exe)
      saved = ENV["PATH"]
      ENV["PATH"] = dir
      assert_equal exe, HeyGcal::Platform.which("fakebin")
      assert_nil HeyGcal::Platform.which("nope")
    ensure
      ENV["PATH"] = saved
    end
  end
end

class SecretStoreTest < Minitest::Test
  include PlatformStubs

  def test_auto_picks_per_os
    config = Fixtures.config
    with_os(:macos) { assert_instance_of HeyGcal::SecretStore::MacKeychain, HeyGcal::SecretStore.for(config) }
    with_os(:windows) { assert_instance_of HeyGcal::SecretStore::WindowsDpapi, HeyGcal::SecretStore.for(config) }
    with_os(:linux, "PATH" => "/nonexistent") { assert_instance_of HeyGcal::SecretStore::PlainFile, HeyGcal::SecretStore.for(config) }
  end

  def test_explicit_file_store_round_trip
    Dir.mktmpdir do |dir|
      with_os(:linux, "XDG_CONFIG_HOME" => dir) do
        store = HeyGcal::SecretStore.for(Fixtures.config("google" => { "token_store" => "file" }))
        assert_instance_of HeyGcal::SecretStore::PlainFile, store
        error = assert_raises(HeyGcal::Error) { store.read }
        assert_equal :google_auth, error.kind

        store.write("1//0abc-DEF_ghi.jkl")
        assert_equal "1//0abc-DEF_ghi.jkl", store.read
        assert_equal 0o600, File.stat(store.path).mode & 0o777 unless Gem.win_platform?
        store.delete
        refute File.exist?(store.path)
      end
    end
  end

  def test_rejects_odd_tokens
    Dir.mktmpdir do |dir|
      with_os(:linux, "XDG_CONFIG_HOME" => dir) do
        store = HeyGcal::SecretStore::PlainFile.new(Fixtures.config)
        error = assert_raises(HeyGcal::Error) { store.write("abc; rm -rf ~") }
        assert_equal :secret_store, error.kind
      end
    end
  end

  def test_fallback_when_keyring_fails
    Dir.mktmpdir do |dir|
      with_os(:linux, "XDG_CONFIG_HOME" => dir) do
        config = Fixtures.config
        broken = Object.new
        def broken.description = "keyring"
        def broken.write(_s) = raise(HeyGcal::Error.new(:secret_store, "no secret service"))
        def broken.read = raise(HeyGcal::Error.new(:google_auth, "missing"))
        def broken.delete = nil
        store = HeyGcal::SecretStore::WithFallback.new(broken, HeyGcal::SecretStore::PlainFile.new(config))
        _out, err = capture_io { store.write("tok123") }
        assert_includes err, "Keyring unavailable"
        assert_equal "tok123", store.read
      end
    end
  end
end
