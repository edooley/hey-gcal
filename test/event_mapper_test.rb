require_relative "test_helper"

class EventMapperTest < Minitest::Test
  M = HeyGcal::EventMapper

  def test_key_prefers_occurrence_id
    assert_equal "1001", M.key(Fixtures.hey_event)
    assert_equal "900_2030-01-15", M.key(Fixtures.hey_event("occurrence_id" => "900_2030-01-15"))
  end

  def test_timed_event
    body = M.build(Fixtures.hey_event)
    assert_equal "Planning sync", body["summary"]
    assert_equal({ "dateTime" => "2030-01-15T18:00:00Z", "timeZone" => "America/Chicago" }, body["start"])
    assert_equal({ "dateTime" => "2030-01-15T18:30:00Z", "timeZone" => "America/Chicago" }, body["end"])
    assert_equal "https://meet.google.com/abc-defg-hij", body["location"]
    refute body.key?("attendees"), "never add real attendees"
    refute body.key?("conferenceData")
  end

  def test_title_prefix
    assert_equal "Work: Planning sync", M.build(Fixtures.hey_event, prefix: "Work: ")["summary"]
    assert_equal "Planning sync", M.build(Fixtures.hey_event)["summary"]
    refute_equal M.hash_of(M.build(Fixtures.hey_event)), M.hash_of(M.build(Fixtures.hey_event, prefix: "Work: "))
  end

  def test_description_full
    description = M.build(Fixtures.hey_event)["description"]
    assert description.start_with?("Join: https://meet.google.com/abc-defg-hij\n\n")
    assert_includes description, "Agenda: roadmap"
    assert_includes description, "Organizer: Ada Example <ada@example.com>"
    assert_includes description, "- bob@example.com (needs action)"
    assert_includes description, "Open in HEY: https://app.hey.com/calendar/events/1001/edit"
  end

  def test_description_minimal
    description = M.build(Fixtures.hey_event, detail: "minimal")["description"]
    assert description.start_with?("Join: https://meet.google.com/abc-defg-hij")
    refute_includes description, "Agenda"
    refute_includes description, "ada@example.com"
  end

  def test_meet_link_strips_query_and_rejects_lookalikes
    assert_equal "https://meet.google.com/abc-defg-hij", M.normalize_meet("https://meet.google.com/abc-defg-hij?authuser=1&hs=7")
    assert_nil M.normalize_meet("https://meet.google.com.evil.example/abc-defg-hij")
    assert_nil M.normalize_meet("http://meet.google.com/abc-defg-hij")
    assert_nil M.normalize_meet("https://meet.google.com/lookup/abc")
    assert_nil M.normalize_meet("javascript:alert(1)")
  end

  def test_join_link_beats_description
    event = Fixtures.hey_event("description" => "Join here instead: https://meet.google.com/bad-badd-bad")
    assert_equal "https://meet.google.com/abc-defg-hij", M.meet_link(event)
  end

  def test_description_fallback_when_no_structured_link
    event = Fixtures.hey_event("join_link" => nil, "location" => "Room 4", "description" => "Dial in: https://meet.google.com/qrs-tuvw-xyz.")
    assert_equal "https://meet.google.com/qrs-tuvw-xyz", M.meet_link(event)
    assert_equal "https://meet.google.com/qrs-tuvw-xyz", M.build(event)["location"]
  end

  def test_no_meet_link
    event = Fixtures.hey_event("join_link" => nil, "location" => "Room 4", "description" => "")
    body = M.build(event)
    assert_nil M.meet_link(event)
    assert_equal "Room 4", body["location"]
    refute_includes body["description"], "Join:"
  end

  def test_all_day_date_only
    body = M.build(Fixtures.hey_event("all_day" => true, "starts_at" => "2030-01-15", "ends_at" => "2030-01-15"))
    assert_equal({ "date" => "2030-01-15" }, body["start"])
    assert_equal({ "date" => "2030-01-16" }, body["end"])
  end

  def test_all_day_midnight_exclusive_end
    body = M.build(Fixtures.hey_event("all_day" => true, "starts_at" => "2030-01-15T00:00:00Z", "ends_at" => "2030-01-17T00:00:00Z"))
    assert_equal({ "date" => "2030-01-15" }, body["start"])
    assert_equal({ "date" => "2030-01-17" }, body["end"])
  end

  def test_all_day_inclusive_end
    body = M.build(Fixtures.hey_event("all_day" => true, "starts_at" => "2030-01-15T00:00:00Z", "ends_at" => "2030-01-16T23:59:59Z"))
    assert_equal({ "date" => "2030-01-17" }, body["end"])
  end

  def test_hash_changes_when_time_moves
    a = M.build(Fixtures.hey_event)
    b = M.build(Fixtures.hey_event("starts_at" => "2030-01-15T19:00:00Z", "ends_at" => "2030-01-15T19:30:00Z"))
    refute_equal M.hash_of(a), M.hash_of(b)
    assert_equal M.hash_of(a), M.hash_of(M.build(Fixtures.hey_event))
  end

  def test_private_properties
    props = M.build(Fixtures.hey_event)["extendedProperties"]["private"]
    assert_equal "1", props["hey_sync"]
    assert_equal "1001", props["hey_key"]
  end

  def test_missing_fields_are_a_cli_error
    error = assert_raises(HeyGcal::Error) { M.build(Fixtures.hey_event("starts_at" => nil)) }
    assert_equal :hey_cli, error.kind
  end
end
