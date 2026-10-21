require_relative "test_helper"

class SyncerTest < Minitest::Test
  TODAY = Date.new(2030, 1, 10)

  def sync(hey_events, google, config: Fixtures.config, today: TODAY, **opts)
    HeyGcal::Syncer.new(hey: FakeHey.new(hey_events), google: google, config: config, today: today, **opts).run
  end

  def test_inserts_then_is_idempotent
    google = FakeGoogle.new
    result = sync([Fixtures.hey_event], google)
    assert_equal 1, result.inserted
    event = google.events.values.first
    assert_equal "https://meet.google.com/abc-defg-hij", event["hangoutLink"]

    google.calls.clear
    result = sync([Fixtures.hey_event], google)
    assert_equal 0, result.plan.writes
    assert_empty google.writes
  end

  def test_updates_when_time_moves
    google = FakeGoogle.new
    sync([Fixtures.hey_event], google)
    moved = Fixtures.hey_event("starts_at" => "2030-01-15T20:00:00Z", "ends_at" => "2030-01-15T21:00:00Z")
    result = sync([moved], google)
    assert_equal 1, result.updated
    assert_equal 1, google.events.size
    assert_equal "2030-01-15T20:00:00Z", google.events.values.first["start"]["dateTime"]
  end

  def test_adding_a_prefix_updates_in_place
    google = FakeGoogle.new
    sync([Fixtures.hey_event], google)
    result = sync([Fixtures.hey_event], google, config: Fixtures.config("sync" => { "title_prefix" => "E90: " }))
    assert_equal 1, result.updated
    assert_equal 0, result.inserted
    assert_equal ["E90: Planning sync"], google.events.values.map { |e| e["summary"] }
  end

  def test_deletes_when_gone_from_hey
    google = FakeGoogle.new
    other = Fixtures.hey_event("id" => 2002, "title" => "Keep me")
    sync([Fixtures.hey_event, other], google)
    result = sync([other], google)
    assert_equal 1, result.deleted
    assert_equal ["Keep me"], google.events.values.map { |e| e["summary"] }
  end

  def test_recreates_event_deleted_on_google
    google = FakeGoogle.new
    sync([Fixtures.hey_event], google)
    stale = google.events.values.first.merge("id" => "missing")
    stale["extendedProperties"]["private"]["hey_hash"] = "old"
    google.events.clear
    google.events["missing"] = stale
    google.define_singleton_method(:list_managed) { |_a, _b| [stale] }
    result = sync([Fixtures.hey_event], google)
    assert_equal 1, result.updated
    assert google.calls.any? { |c| c.first == :insert }
  end

  def test_idempotent_on_primary_calendar_too
    google = FakeGoogle.new(calendar_kind: :primary)
    sync([Fixtures.hey_event], google)
    google.calls.clear
    assert_equal 0, sync([Fixtures.hey_event], google).plan.writes
  end

  def test_removes_duplicates_left_by_an_earlier_bug
    google = FakeGoogle.new
    sync([Fixtures.hey_event], google)
    copy = google.events.values.first
    google.events["dup1"] = copy.merge("id" => "dup1")
    google.events["dup2"] = copy.merge("id" => "dup2")
    result = sync([Fixtures.hey_event], google)
    assert_equal 2, result.deleted
    assert_equal 0, result.inserted
    assert_equal 1, google.events.size
  end

  def test_never_inserts_over_a_marked_event_it_does_not_own
    foreign = {
      "id" => "x9", "summary" => "Planning sync", "creator" => { "email" => "other@example.com" },
      "organizer" => { "email" => "someone-else@example.com" },
      "start" => { "dateTime" => "2030-01-15T18:00:00Z" },
      "extendedProperties" => { "private" => { "hey_sync" => "1", "hey_key" => "1001" } }
    }
    google = FakeGoogle.new
    google.events["x9"] = foreign
    result = sync([Fixtures.hey_event], google)
    assert_equal 0, result.inserted
    assert_equal 1, result.event_errors.size
    assert_equal 1, google.events.size
  end

  def test_ignores_events_it_did_not_create
    foreign = {
      "id" => "x1", "summary" => "Someone else's", "creator" => { "self" => false }, "organizer" => { "email" => "x@example.com" },
      "start" => { "dateTime" => "2030-01-12T10:00:00Z" },
      "extendedProperties" => { "private" => { "hey_sync" => "1", "hey_key" => "999" } }
    }
    google = FakeGoogle.new
    google.events["x1"] = foreign
    sync([Fixtures.hey_event], google)
    assert google.events.key?("x1")
    refute google.calls.any? { |c| c == [:delete, "x1"] }
  end

  def weekly(series, weeks, title: "Weekly")
    (0...weeks).map do |w|
      day = Date.new(2030, 1, 8) + 7 * w
      Fixtures.hey_event("id" => series, "occurrence_id" => "#{series}_#{day}", "title" => title,
                         "starts_at" => "#{day}T15:00:00Z", "ends_at" => "#{day}T16:00:00Z")
    end
  end

  def test_holds_deletes_when_hey_returns_nothing
    google = FakeGoogle.new
    sync([Fixtures.hey_event], google)
    result = sync([], google)
    assert result.plan.held?
    assert_includes result.plan.hold_reason, "HEY returned no events"
    assert_equal 0, result.deleted
    assert_equal 1, google.events.size
  end

  def test_holds_deletes_when_most_separate_events_vanish
    events = (1..8).map { |i| Fixtures.hey_event("id" => i, "title" => "E#{i}") }
    google = FakeGoogle.new
    sync(events, google)
    result = sync(events.first(1), google)
    assert_equal 7, result.plan.held.size
    assert_equal 0, result.deleted
    assert_equal 8, google.events.size

    result = sync(events.first(1), google, allow_deletes: true)
    assert_equal 7, result.deleted
  end

  def test_ending_a_long_series_is_not_held
    series = weekly(900, 13)
    others = (1..3).map { |i| Fixtures.hey_event("id" => i, "title" => "One-off #{i}") }
    google = FakeGoogle.new
    sync(series + others, google)
    result = sync(others, google, today: Date.new(2030, 1, 5))
    refute result.plan.held?, result.plan.hold_reason
    assert_equal 13, result.deleted
    assert_equal 3, google.events.size
  end

  def test_ending_two_series_that_are_most_of_the_calendar_is_not_held
    google = FakeGoogle.new
    sync(weekly(900, 13) + weekly(901, 13, title: "Other") + [Fixtures.hey_event("id" => 1)], google, today: Date.new(2030, 1, 5))
    result = sync([Fixtures.hey_event("id" => 1)], google, today: Date.new(2030, 1, 5))
    refute result.plan.held?, result.plan.hold_reason
    assert_equal 26, result.deleted
  end

  def test_held_deletes_do_not_block_new_and_changed_events
    events = (1..8).map { |i| Fixtures.hey_event("id" => i, "title" => "E#{i}") }
    google = FakeGoogle.new
    sync(events, google)
    renamed = events.first.merge("title" => "E1 renamed")
    added = Fixtures.hey_event("id" => 99, "title" => "New one")
    result = sync([renamed, added], google)
    assert result.plan.held?
    assert_equal 1, result.inserted
    assert_equal 1, result.updated
    assert_includes google.events.values.map { |e| e["summary"] }, "E1 renamed"
    assert_includes google.events.values.map { |e| e["summary"] }, "New one"
    assert_equal 9, google.events.size
  end

  def test_small_deletes_pass
    events = (1..3).map { |i| Fixtures.hey_event("id" => i) }
    google = FakeGoogle.new
    sync(events, google)
    assert_equal 1, sync(events.first(2), google).deleted
  end

  def test_dry_run_writes_nothing
    google = FakeGoogle.new
    result = sync([Fixtures.hey_event], google, dry_run: true)
    assert_equal 1, result.plan.inserts.size
    assert_empty google.writes
  end

  def test_events_outside_window_are_skipped
    far = Fixtures.hey_event("id" => 5, "starts_at" => "2031-06-01T10:00:00Z", "ends_at" => "2031-06-01T11:00:00Z")
    result = sync([far], FakeGoogle.new)
    assert_equal 0, result.inserted
  end

  def test_falls_back_when_google_rejects_conference
    google = FakeGoogle.new
    google.conference_mode = :reject
    result = sync([Fixtures.hey_event, Fixtures.hey_event("id" => 2)], google)
    assert_equal 2, result.inserted
    assert_equal 1, result.warnings.size
    google.events.values.each do |e|
      assert_nil e["hangoutLink"]
      assert_equal "https://meet.google.com/abc-defg-hij", e["location"]
    end
    # The custom attempt is made once per run, not per event.
    assert_equal 3, google.calls.count { |c| c.first == :insert }
  end

  def test_strips_swapped_conference
    google = FakeGoogle.new
    google.conference_mode = :swap
    result = sync([Fixtures.hey_event], google)
    assert_equal 1, result.inserted
    assert_empty result.event_errors
    assert_nil google.events.values.first["hangoutLink"]
  end

  def test_reports_meet_google_will_not_remove
    google = FakeGoogle.new
    google.conference_mode = :auto_add
    result = sync([Fixtures.hey_event], google)
    assert_equal 1, result.event_errors.size
    assert_equal :meet_mismatch, result.event_errors.first[:kind]
  end

  def test_systemic_errors_stop_the_run
    google = FakeGoogle.new
    google.define_singleton_method(:insert) { |_b| raise HeyGcal::Error.new(:network, "timeout") }
    error = assert_raises(HeyGcal::Error) { sync([Fixtures.hey_event], google) }
    assert_equal :network, error.kind
  end
end
