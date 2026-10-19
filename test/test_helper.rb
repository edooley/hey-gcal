$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "hey_gcal"
require "minitest/autorun"
require "tmpdir"

module Fixtures
  module_function

  def hey_event(overrides = {})
    {
      "type" => "Calendar::Event",
      "id" => 1001,
      "occurrence_id" => nil,
      "title" => "Planning sync",
      "starts_at" => "2030-01-15T18:00:00Z",
      "ends_at" => "2030-01-15T18:30:00Z",
      "starts_at_time_zone" => "America/Chicago",
      "ends_at_time_zone" => "America/Chicago",
      "all_day" => nil,
      "location" => "https://meet.google.com/abc-defg-hij",
      "join_link" => { "title" => "Join Google Meet", "url" => "https://meet.google.com/abc-defg-hij" },
      "description" => "Agenda: roadmap",
      "attendance_status" => "accepted",
      "attendances" => [
        { "name" => "Ada Example", "email_address" => "ada@example.com", "status" => "accepted" },
        { "name" => "", "email_address" => "bob@example.com", "status" => "needs_action" }
      ],
      "organizer" => { "name" => "Ada Example", "email_address" => "ada@example.com" },
      "edit_url" => "https://app.hey.com/calendar/events/1001/edit",
      "calendar" => { "id" => 10, "name" => "Work" }
    }.merge(overrides)
  end

  def config(overrides = {})
    data = JSON.parse(JSON.generate(HeyGcal::Config::TEMPLATE))
    data["google"]["calendar_id"] = "test@group.calendar.google.com"
    overrides.each { |section, values| values.is_a?(Hash) ? data[section].merge!(values) : data[section] = values }
    HeyGcal::Config.new("/tmp/hey-gcal-test/config.json", data)
  end
end

class FakeHey
  def initialize(events)
    @events = events
  end

  def events(_from, _to)
    @events.to_h { |e| [HeyGcal::EventMapper.key(e), e] }
  end
end

# Mimics Google: stores events, assigns ids, sets creator/organizer the way the
# real API does for the calendar kind, and can swap or reject conference data.
class FakeGoogle
  attr_reader :events, :calls
  attr_accessor :conference_mode, :calendar_kind

  # What Google says about who made an event depends on the calendar:
  # :secondary (a shared or extra calendar) => creator without self, organizer.self
  # :primary                              => creator.self and organizer.self
  def creator = calendar_kind == :primary ? { "email" => "me@example.com", "self" => true } : { "email" => "me@example.com" }
  def organizer = { "email" => "cal@group.calendar.google.com", "self" => true }

  def initialize(events = [], calendar_kind: :secondary)
    @calendar_kind = calendar_kind
    @events = events.to_h { |e| [e["id"], e] }
    @calls = []
    @next_id = 0
    @conference_mode = :honor
  end

  def list_managed(_min, _max)
    @calls << [:list]
    @events.values
  end

  def insert(body)
    @calls << [:insert, body["summary"]]
    store("g#{@next_id += 1}", body)
  end

  def update(id, body)
    @calls << [:update, id]
    raise HeyGcal::Error.new(:calendar_access, "gone", details: { status: 404 }) unless @events.key?(id)

    store(id, body)
  end

  def delete(id)
    @calls << [:delete, id]
    @events.delete(id)
  end

  def writes
    @calls.reject { |c| c.first == :list }
  end

  private

  def store(id, body)
    event = JSON.parse(JSON.generate(body)).merge("id" => id, "creator" => creator, "organizer" => organizer)
    conference = event.delete("conferenceData")
    case conference_mode
    when :reject
      raise HeyGcal::Error.new(:google_request, "Invalid conference type value.", details: { status: 400 }) if conference
    when :swap
      event["hangoutLink"] = "https://meet.google.com/zzz-zzzz-zzz" if conference
    when :auto_add
      event["hangoutLink"] = "https://meet.google.com/yyy-yyyy-yyy"
    else
      event["conferenceData"] = conference if conference
      event["hangoutLink"] = conference["entryPoints"].first["uri"] if conference
    end
    @events[id] = event
  end
end
