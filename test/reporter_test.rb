require_relative "test_helper"

class ReporterTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @config = Fixtures.config("healthchecks_url" => "https://hc-ping.com/abc")
    dir = @dir
    @config.define_singleton_method(:state_dir) { dir }
    @config.define_singleton_method(:log_dir) { dir }
    @pings = []
    @notes = []
    @reporter = HeyGcal::Reporter.new(@config, pinger: ->(s, b) { @pings << [s, b] },
                                               notifier: ->(t, m) { @notes << t }, out: StringIO.new)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def result(warnings: [])
    plan = HeyGcal::Syncer::Plan.new(inserts: [], updates: [], deletes: [], unchanged: 3)
    HeyGcal::Syncer::Result.new(plan: plan, hey_count: 3, inserted: 1, updated: 0, deleted: 0, warnings: warnings, event_errors: [])
  end

  def test_success_pings_and_records
    @reporter.success(result)
    assert_equal "", @pings.last[0]
    assert_equal 0, @reporter.state["consecutive_failures"]
    assert_empty @notes
    assert File.exist?(@config.log_path)
  end

  def test_actionable_failure_alerts_once_then_recovers
    error = HeyGcal::Error.new(:hey_auth, "signed out")
    @reporter.failure(error)
    @reporter.failure(error)
    assert_equal ["/fail", "/fail"], @pings.map(&:first)
    assert_includes @pings.last[1], "hey auth login"
    assert_equal 1, @notes.size, "notify once per new problem"
    assert_equal 2, @reporter.state["consecutive_failures"]

    @reporter.success(result)
    assert_equal ["hey-gcal: HEY CLI is signed out", "hey-gcal recovered"], @notes
    assert_nil @reporter.state["failure"]
  end

  def test_transient_failures_wait_before_alerting
    error = HeyGcal::Error.new(:network, "timeout")
    2.times { @reporter.failure(error) }
    assert_equal ["/log", "/log"], @pings.map(&:first)
    assert_empty @notes
    @reporter.failure(error)
    assert_equal "/fail", @pings.last[0]
    assert_equal 1, @notes.size
  end

  def test_warnings_go_to_log_ping
    @reporter.success(result(warnings: ["fell back"]))
    assert_equal ["/log", ""], @pings.map(&:first)
  end
end
