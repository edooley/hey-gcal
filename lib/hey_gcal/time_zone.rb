module HeyGcal
  # Just enough time zone handling for repeating events, using the
  # system's own zone database through the TZ environment variable (Ruby's
  # standard library has no zone database of its own).
  #
  # Why it's needed: for a repeating event saved without a time zone (one
  # made in HEY rather than from an emailed invite), HEY's API reports every
  # generated occurrence at the series' original UTC time. Across a daylight
  # saving change that's an hour off: a 9:00 meeting started in October comes
  # back as 8:00 in November. HEY's own calendar keeps it at 9:00, so we do the
  # same: same local wall-clock time, in the event's zone. Reported upstream as
  # https://github.com/basecamp/hey-cli/issues/590. Once HEY serves the right
  # times this changes nothing (occurrence_times returns nil), so it can stay.
  module TimeZone
    NAME = %r{\A[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*\z}
    ZONEINFO_DIRS = %w[/usr/share/zoneinfo /var/db/timezone/zoneinfo /usr/lib/zoneinfo /usr/share/lib/zoneinfo].freeze

    module_function

    # An IANA zone name this system can convert with, or nil.
    def valid?(zone)
      zone.is_a?(String) && zone.match?(NAME) && !zone.include?("..") &&
        ZONEINFO_DIRS.any? { |dir| File.file?(File.join(dir, zone)) }
    end

    # This computer's zone name, e.g. "America/Chicago", or nil if it can't
    # be named (then the system's local time is used as is).
    def system_zone
      env = ENV["TZ"].to_s.delete_prefix(":")
      return env if valid?(env)

      link = File.readlink("/etc/localtime") rescue nil
      zone = link && link[%r{zoneinfo/(.+)\z}, 1]
      return zone if valid?(zone)

      zone = File.read("/etc/timezone").strip rescue nil
      valid?(zone) ? zone : nil
    end

    # Runs the block with Ruby's local time in `zone` (nil = leave as is).
    def within(zone)
      return yield unless zone

      saved = ENV["TZ"]
      ENV["TZ"] = zone
      yield
    ensure
      ENV["TZ"] = saved if zone
    end

    # [hour, minute, second] of a UTC instant, as a clock in `zone` shows it.
    def wall_clock(time, zone)
      within(zone) do
        local = time.getlocal
        [local.hour, local.min, local.sec]
      end
    end

    # The UTC instant when `zone` shows `date` at hour:min:sec.
    def at(date, clock, zone)
      within(zone) { Time.local(date.year, date.month, date.day, *clock).utc }
    end

    # For a generated occurrence of a repeating event, the start and end HEY
    # *means* (the series' wall-clock time on that day), or nil when the
    # event isn't one or nothing needs changing.
    def occurrence_times(event, zone)
      return nil unless event["occurrence_id"] && event["recording_id"].nil? && event["all_day"] != true

      series_start = event.dig("parent", "starts_at")
      day = event["occurrence_id"].to_s[/_(\d{4}-\d{2}-\d{2})\z/, 1]
      return nil unless series_start && day && event["starts_at"] && event["ends_at"]

      starts = Time.iso8601(event["starts_at"])
      duration = Time.iso8601(event["ends_at"]) - starts
      fixed = at(Date.iso8601(day), wall_clock(Time.iso8601(series_start), zone), zone)
      return nil if fixed == starts

      [fixed, fixed + duration]
    rescue ArgumentError
      nil
    end

    # The event with its times corrected, if they needed it.
    def fix_occurrence(event, default_zone)
      zone = valid?(event["starts_at_time_zone"]) ? event["starts_at_time_zone"] : default_zone
      times = occurrence_times(event, zone)
      return event unless times

      event.merge("starts_at" => times[0].iso8601, "ends_at" => times[1].iso8601)
    end
  end
end
