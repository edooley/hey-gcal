require "fileutils"

module HeyGcal
  # Everything a run tells the outside world: the log file, the status file
  # behind `hey-gcal status`, Healthchecks.io pings (which email the user),
  # and a desktop notification when something new goes wrong.
  class Reporter
    LOG_LIMIT = 1_000_000
    TRANSIENT_ALERT_AFTER = 3

    attr_reader :config

    def initialize(config, pinger: nil, notifier: nil, out: $stdout)
      @config = config
      @pinger = pinger || method(:ping)
      @notifier = notifier || ->(title, message) { Platform.notify(title, message, on_click: Omarchy.self_argv(config, "status", "--wait")) }
      @out = out
    end

    def log(line)
      stamped = "#{Time.now.utc.iso8601} #{line}"
      begin
        FileUtils.mkdir_p(config.log_dir, mode: 0o700)
        rotate_log
        File.open(config.log_path, "a", 0o600) { |f| f.puts(stamped) }
      rescue SystemCallError
        nil
      end
      # Under rubyw.exe (Windows background job) there is no console to write to.
      @out.puts(stamped) rescue nil
    end

    def success(result)
      previous = state
      log("ok #{result.summary}")
      result.warnings.each { |w| log("warning: #{w}") }
      @pinger.call("/log", "warnings:\n#{result.warnings.join("\n")}") if result.warnings.any?
      @pinger.call("", "ok #{result.summary}")
      @notifier.call("hey-gcal recovered", "#{config.name} is syncing again.") if previous["alerted"]

      save_state(
        "last_run_at" => now, "last_success_at" => now, "last_summary" => result.summary,
        "consecutive_failures" => 0, "failure" => nil, "alerted" => false
      )
    end

    def failure(error)
      previous = state
      consecutive = previous["consecutive_failures"].to_i + 1
      since = previous.dig("failure", "since") || now
      report = Failure.report(error, config: config, consecutive: consecutive, since: since)
      title = Failure.explain(error, config_path: config.path).title
      log("FAILED #{error.kind}: #{error.message}")

      alert = !error.transient? || consecutive >= TRANSIENT_ALERT_AFTER
      if alert
        @pinger.call("/fail", report)
        new_problem = !previous["alerted"] || previous.dig("failure", "kind") != error.kind.to_s
        @notifier.call("hey-gcal: #{title}", Omarchy.present? ? "Click for what to do." : "Run `hey-gcal status` for what to do.") if new_problem
      else
        @pinger.call("/log", "transient failure #{consecutive}/#{TRANSIENT_ALERT_AFTER}: #{error.message}")
      end

      save_state(
        "last_run_at" => now, "last_success_at" => previous["last_success_at"],
        "last_summary" => previous["last_summary"], "consecutive_failures" => consecutive,
        "failure" => { "kind" => error.kind.to_s, "title" => title, "since" => since, "report" => report },
        "alerted" => previous["alerted"] || alert
      )
      report
    end

    def state
      JSON.parse(File.read(config.state_path))
    rescue Errno::ENOENT, JSON::ParserError
      {}
    end

    private

    def save_state(data)
      FileUtils.mkdir_p(config.state_dir, mode: 0o700)
      tmp = "#{config.state_path}.tmp"
      File.open(tmp, "w", 0o600) { |f| f.write(JSON.pretty_generate(data)) }
      File.rename(tmp, config.state_path)
    end

    def rotate_log
      return unless File.exist?(config.log_path) && File.size(config.log_path) > LOG_LIMIT

      File.rename(config.log_path, "#{config.log_path}.1")
    end

    def now
      Time.now.utc.iso8601
    end

    # Healthchecks.io: "" = success, "/fail" = down (emails), "/log" = note only.
    def ping(suffix, body)
      url = config.healthchecks_url
      return unless url

      host = URI.parse(url).host
      Http.request(:post, "#{url}#{suffix}", headers: { "Content-Type" => "text/plain; charset=utf-8" },
                                             body: body.to_s[0, 90_000], allowed_hosts: [host], timeout: 10)
    rescue Error, ArgumentError => e
      log("warning: could not ping Healthchecks: #{e.message}")
    end
  end
end
