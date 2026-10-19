require_relative "test_helper"
require "open3"

# Background jobs run with no locale (LANG unset), where Ruby defaults to
# reading files as ASCII. Run a fresh Ruby that way and make sure non-ASCII
# config values and HEY titles still work.
class EncodingTest < Minitest::Test
  def test_utf8_without_a_locale
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.generate("google" => { "calendar_id" => "a@b" }, "sync" => { "title_prefix" => "\u{1F7E0} " }))
      hey = File.join(dir, "hey")
      File.write(hey, "#!/bin/sh\nprintf '%s' '#{JSON.generate("ok" => true, "data" => [Fixtures.hey_event("title" => "Café ☕ sync")])}'\n")
      File.chmod(0o755, hey)

      # require (not -r): Ruby applies the locale after -r libraries load,
      # which would undo the fix and isn't how bin/hey-gcal loads it.
      script = <<~RUBY
        require "hey_gcal"
        config = HeyGcal::Config.load(#{path.inspect})
        event = HeyGcal::HeyClient.new(bin: #{hey.inspect}).week(Date.new(2030, 1, 15)).first
        print HeyGcal::EventMapper.build(event, prefix: config.title_prefix)["summary"]
      RUBY
      env = { "LANG" => nil, "LC_ALL" => nil, "LC_CTYPE" => nil, "RUBYOPT" => nil }
      lib = File.expand_path("../lib", __dir__)
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-I", lib, "-e", script)
      assert status.success?, err
      assert_equal "\u{1F7E0} Café ☕ sync", out.force_encoding(Encoding::UTF_8)
    end
  end
end
