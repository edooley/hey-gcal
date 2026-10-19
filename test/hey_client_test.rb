require_relative "test_helper"

class HeyClientTest < Minitest::Test
  def client(stdout: nil, stderr: "", status: 0, events: [Fixtures.hey_event], **opts)
    calls = []
    stdout ||= JSON.generate("ok" => true, "data" => events)
    runner = lambda do |argv|
      calls << argv
      [stdout, stderr, status]
    end
    [HeyGcal::HeyClient.new(bin: "/opt/hey", runner: runner, **opts), calls]
  end

  def test_runs_only_the_read_only_week_command
    hey, calls = client(account: "123")
    hey.week(Date.new(2030, 1, 15))
    assert_equal [["/opt/hey", "event", "week", "2030-01-15", "--json", "--all", "--account", "123"]], calls
  end

  def test_events_dedupes_across_weeks
    hey, calls = client
    events = hey.events(Date.new(2030, 1, 1), Date.new(2030, 1, 20))
    assert_equal ["1001"], events.keys
    assert_operator calls.size, :>=, 3
  end

  def test_filters_declined_and_calendars
    declined = Fixtures.hey_event("id" => 2, "attendance_status" => "declined")
    other_cal = Fixtures.hey_event("id" => 3, "calendar" => { "id" => 11, "name" => "Side project" })
    todo = Fixtures.hey_event("id" => 4, "type" => "Calendar::Todo")
    hey, = client(events: [Fixtures.hey_event, declined, other_cal, todo], calendars: ["Work"])
    assert_equal ["1001"], hey.events(Date.new(2030, 1, 15), Date.new(2030, 1, 15)).keys

    hey, = client(events: [Fixtures.hey_event, declined, other_cal], skip_declined: false)
    assert_equal %w[1001 2 3], hey.events(Date.new(2030, 1, 15), Date.new(2030, 1, 15)).keys
  end

  def test_auth_error
    hey, = client(stdout: JSON.generate("ok" => false, "error" => "not logged in", "code" => "auth"), status: 3)
    error = assert_raises(HeyGcal::Error) { hey.week(Date.today) }
    assert_equal :hey_auth, error.kind
  end

  def test_unexpected_output
    hey, = client(stdout: "<html>", status: 0)
    error = assert_raises(HeyGcal::Error) { hey.week(Date.today) }
    assert_equal :hey_cli, error.kind
  end

  def test_missing_binary
    hey = HeyGcal::HeyClient.new(bin: "/nonexistent/hey")
    error = assert_raises(HeyGcal::Error) { hey.week(Date.today) }
    assert_equal :hey_cli, error.kind
  end
end
