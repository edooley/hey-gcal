require "digest"
require "uri"

module HeyGcal
  # Turns one HEY event occurrence into the Google Calendar event body we want
  # it to look like. Pure functions: no IO, easy to test.
  module EventMapper
    # Bump to force every synced event to be rewritten after a mapping change.
    MAPPING_VERSION = 1
    MEET_LINK = %r{\Ahttps://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}\z}
    MEET_IN_TEXT = %r{https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}(?![a-z-])}
    FOOTER = "Synced one-way from HEY by hey-gcal. Edits made here are overwritten."

    module_function

    # Stable identity across runs: a repeating event's day is "<series>_<date>",
    # a one-off event is its id.
    def key(event)
      (event["occurrence_id"] || event["id"]).to_s
    end

    # The original Meet link, normalized to https://meet.google.com/abc-defg-hij.
    # HEY's structured join link wins over the location, which wins over text
    # found in the description.
    def meet_link(event)
      [event.dig("join_link", "url"), event["location"]].each do |candidate|
        link = normalize_meet(candidate)
        return link if link
      end
      event["description"].to_s[MEET_IN_TEXT]
    end

    def normalize_meet(value)
      uri = URI.parse(value.to_s.strip)
      return nil unless uri.is_a?(URI::HTTPS) && uri.host == "meet.google.com"

      link = "https://meet.google.com#{uri.path}"
      link.match?(MEET_LINK) ? link : nil
    rescue URI::InvalidURIError
      nil
    end

    def meet_code(link)
      link.split("/").last
    end

    def overlaps?(event, window_start, window_end)
      starts, ends = bounds(event)
      ends > window_start && starts < window_end
    end

    # [start, end] as Times, for window checks. All-day events count from UTC
    # midnight, which is close enough for a window measured in days.
    def bounds(event)
      if all_day?(event)
        start_date, end_date = all_day_dates(event)
        [Time.utc(start_date.year, start_date.month, start_date.day), Time.utc(end_date.year, end_date.month, end_date.day)]
      else
        [Time.iso8601(event.fetch("starts_at")), Time.iso8601(event.fetch("ends_at"))]
      end
    end

    # The Google event body, minus conferenceData (the syncer decides that).
    # prefix (e.g. "Work: ") goes in front of every title, exactly as given.
    def build(event, detail: "full", prefix: "")
      validate!(event)
      link = meet_link(event)
      title = event["title"].to_s.strip.empty? ? "(untitled)" : event["title"].to_s
      body = {
        "summary" => "#{prefix}#{title}",
        "location" => link || event["location"].to_s,
        "description" => description(event, link, detail),
        "transparency" => "opaque"
      }.merge(times(event))
      body["extendedProperties"] = {
        "private" => { "hey_sync" => "1", "hey_key" => key(event), "hey_hash" => digest(body) }
      }
      body
    end

    def hash_of(google_event)
      google_event.dig("extendedProperties", "private", "hey_hash")
    end

    # What Google's own join button should hold for a given Meet link.
    def conference_data(link)
      {
        "conferenceId" => meet_code(link),
        "conferenceSolution" => { "key" => { "type" => "hangoutsMeet" } },
        "entryPoints" => [{ "entryPointType" => "video", "uri" => link, "label" => link.delete_prefix("https://") }]
      }
    end

    # The Meet link Google will show for an event it returned, if any.
    def google_join_link(google_event)
      link = google_event["hangoutLink"]
      link ||= Array(google_event.dig("conferenceData", "entryPoints")).find { |e| e["entryPointType"] == "video" }&.fetch("uri", nil)
      link && normalize_meet(link) || link
    end

    def validate!(event)
      missing = %w[id starts_at ends_at].reject { |field| event[field] }
      return if missing.empty?

      raise Error.new(:hey_cli, "A HEY event is missing #{missing.join(", ")}; the hey CLI's output format may have changed")
    end

    def all_day?(event)
      event["all_day"] == true
    end

    def times(event)
      if all_day?(event)
        start_date, end_date = all_day_dates(event)
        { "start" => { "date" => start_date.iso8601 }, "end" => { "date" => end_date.iso8601 } }
      else
        {
          "start" => timed(event["starts_at"], event["starts_at_time_zone"]),
          "end" => timed(event["ends_at"], event["ends_at_time_zone"] || event["starts_at_time_zone"])
        }
      end
    end

    def timed(at, zone)
      { "dateTime" => Time.iso8601(at).utc.iso8601, "timeZone" => zone || "UTC" }
    end

    # Google wants an exclusive end date. HEY may send "2026-09-02" or
    # "2026-09-02T00:00:00Z"; an end that is not midnight is taken as the
    # last day itself.
    def all_day_dates(event)
      start_date = Date.parse(event["starts_at"].to_s[0, 10])
      end_text = event["ends_at"].to_s
      end_date = Date.parse(end_text[0, 10])
      end_date += 1 if end_text.length > 10 && !end_text[11, 8].to_s.start_with?("00:00:00")
      end_date = start_date + 1 if end_date <= start_date
      [start_date, end_date]
    end

    def description(event, link, detail)
      parts = []
      parts << "Join: #{link}" if link
      if detail == "full"
        notes = event["description"].to_s.strip
        parts << notes unless notes.empty?
        people = people(event)
        parts << people unless people.empty?
        parts << "Open in HEY: #{event["edit_url"]}" if event["edit_url"]
      end
      parts << FOOTER
      parts.join("\n\n")
    end

    def people(event)
      lines = []
      organizer = event["organizer"]
      lines << "Organizer: #{person(organizer)}" if organizer
      attendees = Array(event["attendances"]).map { |a| "- #{person(a)}#{" (#{a["status"].tr("_", " ")})" if a["status"]}" }
      lines << "Guests:\n#{attendees.join("\n")}" unless attendees.empty?
      lines.join("\n")
    end

    def person(hash)
      name = hash["name"].to_s.strip
      email = hash["email_address"].to_s.strip
      return email if name.empty?
      return name if email.empty?

      "#{name} <#{email}>"
    end

    def digest(body)
      Digest::SHA256.hexdigest(JSON.generate([MAPPING_VERSION, body]))[0, 32]
    end
  end
end
