require_relative "test_helper"

# HEY reports generated days of a zone-less repeating event at the series'
# original UTC time, which is an hour off after a daylight saving change.
class TimeZoneTest < Minitest::Test
  TZ = HeyGcal::TimeZone

  def setup
    skip "no zone database on this system" unless TZ.valid?("America/Chicago")
  end

  # Weekly 9:00 Central series from Oct 21 2026; DST ends Nov 1.
  def occurrence(day, starts_at, overrides = {})
    {
      "type" => "Calendar::Event", "id" => 500, "title" => "Weekly", "occurrence_id" => "500_#{day}",
      "recording_id" => nil, "parent_id" => 500, "all_day" => nil,
      "starts_at" => starts_at, "ends_at" => (Time.iso8601(starts_at) + 3600).utc.iso8601,
      "starts_at_time_zone" => nil, "parent" => { "starts_at" => "2026-10-21T14:00:00Z" }
    }.merge(overrides)
  end

  def test_keeps_wall_clock_time_across_dst_end
    fixed = TZ.fix_occurrence(occurrence("2026-11-04", "2026-11-04T14:00:00Z"), "America/Chicago")
    assert_equal "2026-11-04T15:00:00Z", fixed["starts_at"]
    assert_equal "2026-11-04T16:00:00Z", fixed["ends_at"]
  end

  def test_before_dst_change_is_untouched
    event = occurrence("2026-10-21", "2026-10-21T14:00:00Z")
    assert_same event, TZ.fix_occurrence(event, "America/Chicago")
  end

  def test_keeps_wall_clock_time_across_dst_start
    event = occurrence("2027-03-17", "2027-03-17T15:00:00Z", "parent" => { "starts_at" => "2027-01-06T15:00:00Z" })
    assert_equal "2027-03-17T14:00:00Z", TZ.fix_occurrence(event, "America/Chicago")["starts_at"]
  end

  def test_written_out_day_is_trusted
    event = occurrence("2026-11-04", "2026-11-04T14:00:00Z", "recording_id" => 501)
    assert_same event, TZ.fix_occurrence(event, "America/Chicago")
  end

  def test_one_off_event_is_trusted
    event = occurrence("2026-11-04", "2026-11-04T14:00:00Z", "occurrence_id" => nil)
    assert_same event, TZ.fix_occurrence(event, "America/Chicago")
  end

  def test_all_day_is_untouched
    event = occurrence("2026-11-04", "2026-11-04T14:00:00Z", "all_day" => true)
    assert_same event, TZ.fix_occurrence(event, "America/Chicago")
  end

  def test_event_zone_wins_over_default
    event = occurrence("2026-11-04", "2026-11-04T14:00:00Z", "starts_at_time_zone" => "America/New_York",
                                                            "parent" => { "starts_at" => "2026-10-21T13:00:00Z" })
    assert_equal "2026-11-04T14:00:00Z", TZ.fix_occurrence(event, "America/Chicago")["starts_at"]
  end

  def test_restores_tz_env
    saved = ENV["TZ"]
    TZ.fix_occurrence(occurrence("2026-11-04", "2026-11-04T14:00:00Z"), "Asia/Tokyo")
    saved.nil? ? assert_nil(ENV["TZ"]) : assert_equal(saved, ENV["TZ"])
  end

  def test_rejects_bad_zone_names
    refute TZ.valid?("../../etc/passwd")
    refute TZ.valid?("Not/AZone")
    assert TZ.valid?("Europe/London")
  end

  def test_hey_client_applies_fix_and_default_zone
    runner = ->(_argv) { [JSON.generate("ok" => true, "data" => [occurrence("2026-11-04", "2026-11-04T14:00:00Z")]), "", 0] }
    hey = HeyGcal::HeyClient.new(bin: "hey", runner: runner, time_zone: "America/Chicago")
    event = hey.events(Date.new(2026, 11, 4), Date.new(2026, 11, 4)).values.first
    assert_equal "2026-11-04T15:00:00Z", event["starts_at"]
    assert_equal "America/Chicago", event["starts_at_time_zone"]
  end
end
