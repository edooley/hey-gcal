require "open3"

module HeyGcal
  # Read-only access to HEY through the logged-in `hey` CLI. The only commands
  # this class can run are `hey event week <date> --json --all` and
  # `hey auth status --json`; it never sees HEY credentials and has no way to
  # write to HEY.
  class HeyClient
    DATE_FORMAT = /\A\d{4}-\d{2}-\d{2}\z/
    TIMEOUT = 90

    # runner: anything responding to #call(argv) => [stdout, stderr, exit_status]
    # time_zone: the zone for events HEY stored without one (default: this
    # computer's). See TimeZone for why it matters.
    def initialize(bin: nil, account: nil, calendars: [], skip_declined: true, time_zone: nil, runner: nil)
      @bin = bin || ENV["HEY_GCAL_HEY_BIN"] || "hey"
      @time_zone = time_zone || TimeZone.system_zone
      @account = account
      @calendars = calendars.map(&:to_s)
      @skip_declined = skip_declined
      @runner = runner || method(:run)
    end

    # Every event HEY draws in the weeks covering from..to, keyed by
    # EventMapper.key, after the calendar and declined filters.
    def events(from, to)
      events = {}
      date = from
      while date <= to + 6
        week(date).each do |event|
          next unless keep?(event)

          events[EventMapper.key(event)] = normalize(event)
        end
        date += 7
      end
      events
    end

    def week(date)
      day = date.strftime("%Y-%m-%d")
      raise ArgumentError, "bad date" unless day.match?(DATE_FORMAT)

      argv = [@bin, "event", "week", day, "--json", "--all"]
      argv += ["--account", @account] if @account
      stdout, stderr, status = @runner.call(argv)
      parse(stdout, stderr, status)
    end

    # true when the hey CLI is installed and signed in.
    def signed_in?
      stdout, _stderr, _status = @runner.call([@bin, "auth", "status", "--json"])
      JSON.parse(stdout.to_s).dig("data", "authenticated") == true
    rescue JSON::ParserError, Error
      false
    end

    private

    # Repeating-event days HEY generated get the series' wall-clock time
    # (see TimeZone), and events stored without a zone get the default one.
    def normalize(event)
      event = TimeZone.fix_occurrence(event, @time_zone)
      return event unless @time_zone && event["all_day"] != true

      event.merge(
        "starts_at_time_zone" => event["starts_at_time_zone"] || @time_zone,
        "ends_at_time_zone" => event["ends_at_time_zone"] || event["starts_at_time_zone"] || @time_zone
      )
    end

    def keep?(event)
      return false unless event["type"].nil? || event["type"] == "Calendar::Event"
      return false if @skip_declined && event["attendance_status"] == "declined"
      return true if @calendars.empty?

      calendar = event["calendar"] || {}
      @calendars.include?(calendar["id"].to_s) || @calendars.include?(calendar["name"].to_s)
    end

    def parse(stdout, stderr, status)
      envelope = begin
        JSON.parse(stdout.to_s)
      rescue JSON::ParserError
        nil
      end

      if envelope.is_a?(Hash) && envelope["ok"] == true && envelope["data"].is_a?(Array)
        return envelope["data"]
      end

      # hey's error envelope: {"ok": false, "error": "...", "code": "auth", "hint": "..."}
      code = envelope.is_a?(Hash) ? envelope["code"] : nil
      message = envelope.is_a?(Hash) ? [envelope["error"], envelope["hint"]].compact.join(" - ") : ""
      message = stderr.to_s.strip if message.empty?
      message = message.to_s[0, 500]

      if status == 3 || code.to_s == "auth" || message =~ /could not read stored credentials/i
        raise Error.new(:hey_auth, "The hey CLI is not logged in (#{message})")
      elsif status.zero?
        raise Error.new(:hey_cli, "hey answered in an unexpected shape: #{stdout.to_s[0, 200]}")
      else
        raise Error.new(:hey_cli, "hey exited #{status}: #{message}")
      end
    end

    def run(argv)
      env = { "HEY_NONINTERACTIVE" => "1" }
      Open3.popen3(env, *argv) do |stdin, stdout, stderr, thread|
        stdin.close
        out_reader = Thread.new { stdout.read }
        err_reader = Thread.new { stderr.read }
        unless thread.join(TIMEOUT)
          Process.kill(Platform.windows? ? "KILL" : "TERM", thread.pid)
          raise Error.new(:hey_cli, "hey did not answer within #{TIMEOUT}s")
        end
        [out_reader.value.force_encoding(Encoding::UTF_8), err_reader.value.force_encoding(Encoding::UTF_8), thread.value.exitstatus]
      end
    rescue Errno::ENOENT
      raise Error.new(:hey_cli, "The hey CLI was not found (looked for #{@bin.inspect})")
    end
  end
end
