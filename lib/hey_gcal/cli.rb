require "optparse"
require "fileutils"

module HeyGcal
  class CLI
    USAGE = <<~TEXT
      Usage: hey-gcal <command> [options]

      Getting started:
        setup       Guided setup: checks everything, asks for what it needs, turns the sync on

      Commands:
        status      Is it running? Last sync, any problem, and what to do
        doctor      Check every piece of the setup, one by one
        sync        Run one sync now (what the background job runs)
        auth        Sign in to Google again
        install     Start the background job
        uninstall   Stop the background job (--forget also deletes the saved Google sign-in)
        init        Just write a config template
        bar         Print status as Waybar-style JSON (used by the Omarchy bar icon)

      Options:
    TEXT

    def initialize(stdin: $stdin, stdout: $stdout)
      @in = stdin
      @out = stdout
      @options = { config: Config::DEFAULT_PATH, interval: 300, dry_run: false, allow_deletes: false, forget: false, hey_bin: nil, wait: false, bar: true }
    end

    def start(argv)
      command = argv.shift
      parser.parse!(argv)
      case command
      when "setup" then setup
      when "init" then init
      when "auth" then auth
      when "sync" then sync
      when "status" then status
      when "doctor" then doctor
      when "install" then install
      when "uninstall" then uninstall
      when "bar" then bar
      when "version", "--version" then say(VERSION) || 0
      else
        say parser
        command.nil? || %w[help -h --help].include?(command) ? 0 : 1
      end
    rescue OptionParser::ParseError => e
      warn e.message
      1
    rescue Error => e
      warn "\n#{e.message}"
      explanation = Failure.explain(e, config_path: config_path)
      warn "\nWhat to do:"
      explanation.actions.each_with_index { |a, i| warn "  #{i + 1}. #{a}" }
      1
    rescue Interrupt
      warn "\nStopped."
      130
    end

    private

    def parser
      @parser ||= OptionParser.new do |o|
        o.banner = USAGE
        o.on("--config PATH", "Config file (default #{Config::DEFAULT_PATH})") { |v| @options[:config] = File.expand_path(v) }
        o.on("--dry-run", "sync: show what would change, write nothing") { @options[:dry_run] = true }
        o.on("--allow-deletes", "sync: apply deletes even past the safety limits") { @options[:allow_deletes] = true }
        o.on("--interval SECONDS", Integer, "install: seconds between runs (default 300)") { |v| @options[:interval] = v }
        o.on("--forget", "uninstall: also delete the saved Google sign-in") { @options[:forget] = true }
        o.on("--hey-bin PATH", "Path to the hey CLI (default: found on PATH)") { |v| @options[:hey_bin] = v }
        o.on("--wait", "status: wait for a key before exiting (for terminals opened from the bar)") { @options[:wait] = true }
        o.on("--no-bar", "install: on Omarchy, don't add the bar icon") { @options[:bar] = false }
      end
    end

    def config_path = @options[:config]

    def config_flag
      config_path == Config::DEFAULT_PATH ? "" : " --config #{config_path}"
    end

    def say(text = "")
      @out.puts(text)
    end

    # ---- setup -------------------------------------------------------------

    def setup
      say "hey-gcal setup: copies your HEY calendar onto a Google calendar."
      say "Re-run it any time; finished steps are skipped.\n\n"

      step("1/6", "HEY CLI") { setup_hey }
      step("2/6", "Config file") { setup_config }
      step("3/6", "Google OAuth client") { setup_client_secret }
      step("4/6", "Google calendar") { setup_calendar }
      step("5/6", "Failure emails (optional)") { setup_healthchecks }
      step("6/6", "Google sign-in") { setup_auth }

      say "\nHere is what the first sync would do:\n\n"
      @options[:dry_run] = true
      sync
      @options[:dry_run] = false

      if ask_yes?("\nSync now, then every #{@options[:interval] / 60} minutes in the background?")
        sync
        install
        say "\nAll set. Check on it any time with: hey-gcal status#{config_flag}"
      else
        say "\nNothing was written. Run `hey-gcal sync#{config_flag}` and `hey-gcal install#{config_flag}` when you're ready."
      end
      0
    end

    def step(number, title)
      say "[#{number}] #{title}"
      yield
      say ""
    end

    def setup_hey
      hey = resolve_hey(nil)
      unless hey
        say "  The hey CLI isn't installed (or isn't on your PATH)."
        if Omarchy.present?
          say "  Install it the Omarchy way: omarchy-mise-install github:basecamp/hey-cli hey"
          say "  then run `hey auth login` and re-run setup."
        else
          say "  Install it: https://github.com/basecamp/hey-cli#install , run `hey auth login`, then re-run setup."
        end
        raise Error.new(:hey_cli, "The hey CLI was not found")
      end
      unless HeyClient.new(bin: hey).signed_in?
        say "  Found #{hey}, but it isn't signed in. Run `hey auth login`, then re-run setup."
        raise Error.new(:hey_auth, "The hey CLI is not signed in")
      end
      say "  OK: #{hey} is signed in."
    end

    def setup_config
      if Config.init(config_path)
        say "  Created #{config_path} (only you can read it)."
      else
        say "  Using #{config_path}."
      end
    end

    def setup_client_secret
      config = Config.load(config_path, require_calendar: false)
      if valid_client_file?(config.client_secret_path)
        say "  OK: #{config.client_secret_path}"
        return
      end

      say "  hey-gcal needs your own Google OAuth client (a small JSON file you download from"
      say "  Google Cloud Console). Step-by-step instructions, about 10 minutes:"
      say "  https://github.com/edooley/hey-gcal#3-create-your-google-oauth-client"
      found = Dir.glob(File.join(Dir.home, "Downloads", "client_secret_*.json")).max_by { |f| File.mtime(f) }
      source = nil
      if found && valid_client_file?(found) && ask_yes?("  Use #{found}?")
        source = found
      end
      until source
        answer = clean_path(ask("  Path to the downloaded client_secret JSON (you can drag the file here):"))
        if valid_client_file?(answer)
          source = answer
        else
          say "  That isn't a Google \"Desktop app\" OAuth client JSON. Try again (Ctrl-C to stop)."
        end
      end

      FileUtils.mkdir_p(File.dirname(config.client_secret_path), mode: 0o700)
      FileUtils.cp(source, config.client_secret_path)
      File.chmod(0o600, config.client_secret_path)
      say "  Saved to #{config.client_secret_path} (only you can read it)."
      if ask_yes?("  Delete the copy at #{source}?")
        File.delete(source)
      end
    end

    def setup_calendar
      setup_calendar_id
      setup_title_prefix
    end

    def setup_calendar_id
      config = Config.load(config_path, require_calendar: false)
      unless config.calendar_id.to_s.strip.empty? || config.calendar_id == Config::CALENDAR_PLACEHOLDER
        say "  OK: #{config.calendar_id}"
        return
      end

      say "  In Google Calendar: hover the calendar > ⋮ > Settings and sharing > Integrate calendar > Calendar ID."
      say "  (Tip: a separate calendar, e.g. \"Work\", is easiest to show, hide or share.)"
      id = nil
      until id
        answer = ask("  Calendar ID:").strip
        id = answer if answer.match?(/\A[^\s@]+@[^\s@]+\z/)
        say "  Calendar IDs look like abc123@group.calendar.google.com (or your Gmail address)." unless id
      end
      Config.update(config.path) { |data| data["google"]["calendar_id"] = id }
      say "  Saved."
    end

    # Asked once; afterwards it's sync.title_prefix in the config.
    def setup_title_prefix
      config = Config.load(config_path, require_calendar: false)
      raw = JSON.parse(File.read(config.path))
      if raw.dig("sync")&.key?("title_prefix")
        say "  Title prefix: #{config.title_prefix.empty? ? "none" : config.title_prefix.inspect}"
        return
      end

      say "  Optional: a prefix for every copied title, e.g. \"Work: \" turns \"Standup\" into \"Work: Standup\"."
      prefix = nil
      until prefix
        answer = ask("  Title prefix (press Enter for none):").chomp
        answer = "#{answer} " unless answer.empty? || answer.end_with?(" ")
        if answer.length <= 40
          prefix = answer
        else
          say "  Keep it to 40 characters."
        end
      end
      Config.update(config.path) { |data| (data["sync"] ||= {})["title_prefix"] = prefix }
      say prefix.empty? ? "  No prefix." : "  Saved: titles will look like #{(prefix + "Standup").inspect}."
    end

    def setup_healthchecks
      config = Config.load(config_path, require_calendar: false)
      if config.healthchecks_url
        say "  OK: alerts go to your Healthchecks.io check."
        return
      end

      say "  Healthchecks.io (free) emails you if the sync breaks or stops running."
      say "  Create a check with Period = #{@options[:interval] / 60} minutes, and a Grace Time of however long the sync"
      say "  may go quiet before you want an email (1 day suits a laptop that is often closed)."
      say "  Then paste its ping URL."
      say "  How: https://github.com/edooley/hey-gcal#5-failure-emails-with-healthchecksio-recommended"
      loop do
        answer = ask("  Ping URL (or press Enter to skip):").strip
        if answer.empty?
          say "  Skipped. You can add healthchecks_url to the config later."
          return
        end
        if answer.match?(%r{\Ahttps://[A-Za-z0-9.-]+(:\d+)?/[A-Za-z0-9/_-]+\z})
          hours = ask_hours("  The Grace Time you chose, in hours [#{config.stale_after_hours}]:", config.stale_after_hours)
          Config.update(config.path) do |data|
            data["healthchecks_url"] = answer
            data["stale_after_hours"] = hours
          end
          say "  Saved. Local warnings (status, the Omarchy bar) will also kick in after #{hours} h without a sync."
          return
        end
        say "  That doesn't look like an https ping URL (https://hc-ping.com/...)."
      end
    end

    def setup_auth
      config = Config.load(config_path)
      store = SecretStore.for(config)
      token = (store.read rescue nil)
      if token
        begin
          google_client(config, token).check_access
          say "  OK: already signed in, and the calendar is reachable."
          return
        rescue Error => e
          say "  The saved sign-in didn't work (#{e.message}); signing in again."
        end
      end
      auth
    end

    # ---- commands ----------------------------------------------------------

    def init
      if Config.init(config_path)
        say "Wrote #{config_path}"
      else
        say "#{config_path} already exists; left it alone."
      end
      say "\nNext: hey-gcal setup#{config_flag}  (or fill it in by hand; see the README)"
      0
    end

    def auth
      config = Config.load(config_path, require_calendar: false)
      client_id, client_secret = config.client_credentials
      say "  Opening Google sign-in in your browser. If it doesn't open, visit:"
      say "  Google will say \"Google hasn't verified this app\": it's your own app, so choose"
      say "  Advanced > Go to hey-gcal, then allow access to calendar events."
      token = OAuth.authorize(client_id: client_id, client_secret: client_secret, open: lambda { |url|
        say "\n#{url}\n\n"
        Platform.open_url(url)
      })
      store = SecretStore.for(config)
      store.write(token)
      say "  Saved the Google sign-in in #{store.description}."

      if config.calendar_id && config.calendar_id != Config::CALENDAR_PLACEHOLDER
        google_client(config, token).check_access
        say "  The calendar #{config.calendar_id} is reachable."
      end
      0
    end

    def sync
      config = Config.load(config_path)
      reporter = Reporter.new(config, out: @options[:dry_run] ? File.open(File::NULL, "w") : @out)

      with_lock(config) do
        result = Syncer.new(
          hey: HeyClient.new(bin: @options[:hey_bin] || config.hey_bin, account: config.hey_account, time_zone: config.hey_time_zone,
                             calendars: config.hey_calendars, skip_declined: config.skip_declined?),
          google: google_client(config, SecretStore.for(config).read),
          config: config,
          log: ->(line) { reporter.log(line) },
          dry_run: @options[:dry_run],
          allow_deletes: @options[:allow_deletes]
        ).run

        return print_plan(result) if @options[:dry_run]

        if result.plan.held?
          # Everything else was applied; only these deletes wait for a person.
          reporter.log("applied #{result.summary}")
          held = result.plan.held
          error = Error.new(:circuit_breaker, "Holding back #{held.size} deletes: #{result.plan.hold_reason}.",
                            details: { deletes: held.map { |d| Syncer.describe_google(d[:google]) }, events: result.event_errors })
          reporter.failure(error)
          return 1
        end

        if result.event_errors.any?
          kinds = result.event_errors.map { |e| e[:kind] }.uniq
          error = Error.new(kinds == [:meet_mismatch] ? :meet_mismatch : :partial,
                            "#{result.event_errors.size} of #{result.plan.writes} event changes failed",
                            details: { events: result.event_errors })
          reporter.failure(error)
          return 1
        end

        reporter.success(result)
        0
      end
    rescue Error => e
      raise if @options[:dry_run] || e.kind == :config

      reporter.failure(e)
      1
    rescue StandardError => e
      raise if @options[:dry_run] || reporter.nil?

      reporter.failure(Error.new(:crash, "#{e.class}: #{e.message}", details: { backtrace: e.backtrace }))
      1
    end

    def print_plan(result)
      plan = result.plan
      say "DRY RUN - nothing will be written"
      say "#{result.hey_count} HEY events in the window."
      say
      say "Would add #{plan.inserts.size}:"
      plan.inserts.each { |i| say "  + #{line_for(i[:body])}" }
      say "Would update #{plan.updates.size}:"
      plan.updates.each { |i| say "  ~ #{line_for(i[:body])}" }
      say "Would delete #{plan.deletes.size}:"
      plan.deletes.each { |i| say "  - #{line_for(i[:google])}" }
      if plan.held?
        say "Would hold back #{plan.held.size} deletes (#{plan.hold_reason}):"
        plan.held.each { |i| say "  ? #{line_for(i[:google])}" }
        say "  Apply them with: hey-gcal sync --allow-deletes#{config_flag}"
      end
      say "Unchanged: #{plan.unchanged}"
      0
    end

    def line_for(body)
      start = body.dig("start", "dateTime") || body.dig("start", "date")
      start = Time.iso8601(start).localtime.strftime("%a %b %-d %Y %-l:%M%P") if start.to_s.length > 10
      link = body["location"].to_s[EventMapper::MEET_IN_TEXT]
      "#{start}  #{body["summary"]}#{"  [Meet: #{link}]" if link}"
    end

    def status
      config = Config.load(config_path, require_calendar: false)
      state = Reporter.new(config).state
      job = Scheduler.for(config).status(config.name)

      say "hey-gcal (#{config.name}) -> #{config.calendar_id}"
      say "Background job: #{job[:installed] ? job[:summary] : "not installed - run `hey-gcal install#{config_flag}`"}"
      say "Last run:       #{local(state["last_run_at"]) || "never"}"
      say "Last success:   #{local(state["last_success_at"]) || "never"}#{"  (#{state["last_summary"]})" if state["last_summary"]}"
      say "Failure emails: #{config.healthchecks_url ? "on (Healthchecks.io)" : "off - see README step 5"}"
      say "Log:            #{config.log_path}"
      say "Bar icon:       #{Omarchy.bar_module?(config) ? "on" : "off - run `hey-gcal install#{config_flag}`"}" if Omarchy.present?
      code =
        if state["failure"]
          say
          say "PROBLEM (#{state["consecutive_failures"]} failed run#{"s" unless state["consecutive_failures"] == 1} in a row):"
          say
          say state["failure"]["report"]
          1
        elsif stale?(state, config)
          say "Health:         no successful sync for #{Omarchy.ago(Time.now - Time.iso8601(state["last_success_at"]))} (expected within #{config.stale_after_hours} h)"
          say "                Is the background job running? Try `hey-gcal doctor#{config_flag}`."
          1
        else
          say "Health:         #{state["last_run_at"] ? "OK" : "not run yet"}"
          0
        end
      wait_for_key(code) if @options[:wait]
      code
    end

    def stale?(state, config)
      state["last_success_at"] && Time.now - Time.iso8601(state["last_success_at"]) > config.stale_after_seconds
    end

    # Omarchy bar icon: one JSON line, read from the status file only.
    def bar
      config = Config.load(config_path, require_calendar: false)
      say Omarchy.bar_json(Reporter.new(config, out: File.open(File::NULL, "w")).state, config)
      0
    end

    def wait_for_key(code)
      if Platform.which("omarchy-show-done")
        system("omarchy-show-done", code.to_s)
      else
        @out.print("\nPress Enter to close.")
        @in.gets
      end
    end

    def doctor
      checks = []
      check = lambda do |label, &probe|
        detail = probe.call
        checks << true
        say "  ok    #{label}#{" - #{detail}" if detail.is_a?(String)}"
      rescue Error, StandardError => e
        checks << false
        say "  FAIL  #{label} - #{e.message}"
      end

      say "hey-gcal doctor (#{Platform.os}, Ruby #{RUBY_VERSION})"
      check.call("Ruby 3.0 or newer") { Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.0") or raise "Ruby #{RUBY_VERSION} is too old" }
      check.call("config #{config_path}") { Config.load(config_path) && nil }
      config = (Config.load(config_path, require_calendar: false) rescue nil)
      hey = nil
      check.call("hey CLI installed") { (hey = resolve_hey(config)) or raise "not found on PATH" }
      check.call("hey CLI signed in") { HeyClient.new(bin: hey).signed_in? or raise "run `hey auth login`" } if hey
      if config
        check.call("Google OAuth client") { config.client_credentials && config.client_secret_path }
        token = nil
        check.call("Google sign-in saved") { (token = SecretStore.for(config).read) && SecretStore.for(config).description }
        if token && config.calendar_id != Config::CALENDAR_PLACEHOLDER
          check.call("Google calendar reachable") { google_client(config, token).check_access && config.calendar_id }
        end
        check.call("background job") do
          job = Scheduler.for(config).status(config.name)
          job[:installed] or raise "not installed - run `hey-gcal install#{config_flag}`"
          job[:summary]
        end
        if Omarchy.present?
          if Omarchy.bar_module?(config)
            check.call("Omarchy bar icon") { "on" }
          else
            say "  --    Omarchy bar icon - off (optional; `hey-gcal install` adds it)"
          end
        end
        if config.healthchecks_url
          check.call("failure emails") { "Healthchecks.io" }
        else
          say "  --    failure emails - off (optional, but nothing will tell you if the sync stops; README step 5)"
        end
      end
      checks.all? ? 0 : 1
    end

    def install
      config = Config.load(config_path)
      hey = resolve_hey(config) or raise Error.new(:hey_cli, "Could not find the hey CLI on PATH; pass --hey-bin or set hey.bin in the config")
      scheduler = Scheduler.for(config)
      scheduler.install(Scheduler.job(config, interval: @options[:interval], hey: hey))
      say "Background job installed: #{scheduler.description(config.name)}"
      if Omarchy.present? && @options[:bar]
        Omarchy.add_bar_module(config)
        say "Added a calendar icon to your Omarchy bar: click it for status, right-click to sync now."
        say "(Your previous shell.json was saved as shell.json.hey-gcal.bak. Use --no-bar to skip this.)"
      end
      say "It runs every #{@options[:interval] / 60} minutes in the background. Check on it with: hey-gcal status#{config_flag}"
      say "(macOS may ask once whether hey-gcal may use your Keychain: choose Always Allow.)" if Platform.macos?
      0
    end

    def uninstall
      config = Config.load(config_path, require_calendar: false)
      scheduler = Scheduler.for(config)
      scheduler.uninstall(config.name)
      say "Stopped and removed the background job."
      if Omarchy.present? && Omarchy.bar_module?(config)
        Omarchy.remove_bar_module(config)
        say "Removed the hey-gcal icon from your Omarchy bar."
      end
      if @options[:forget]
        SecretStore.for(config).delete
        say "Deleted the saved Google sign-in. Also revoke access at https://myaccount.google.com/permissions"
      else
        say "The Google sign-in is still saved; run with --forget to delete it too."
      end
      0
    end

    # ---- helpers -----------------------------------------------------------

    def resolve_hey(config)
      candidate = @options[:hey_bin] || config&.hey_bin || ENV["HEY_GCAL_HEY_BIN"]
      return File.expand_path(candidate) if candidate && File.exist?(File.expand_path(candidate))

      Platform.which("hey")
    end

    def valid_client_file?(path)
      return false unless path && File.file?(path)

      json = JSON.parse(File.read(path))
      creds = json["installed"]
      creds.is_a?(Hash) && creds["client_id"] && creds["client_secret"]
    rescue JSON::ParserError, SystemCallError
      false
    end

    # Terminals add quotes or backslash-escapes when you drag a file in.
    def clean_path(text)
      text = text.strip
      text = text[1..-2] if text.length > 1 && %w[' "].include?(text[0]) && text[-1] == text[0]
      text = text.gsub(/\\(.)/, '\1') unless Platform.windows?
      File.expand_path(text)
    end

    def ask(prompt)
      @out.print("#{prompt} ")
      answer = @in.gets
      raise Interrupt if answer.nil?

      answer.chomp
    end

    def ask_hours(prompt, default)
      loop do
        answer = ask(prompt).strip
        return default if answer.empty?

        value = Float(answer, exception: false)
        return value % 1 == 0 ? value.to_i : value if value&.positive?

        say "  Enter a number of hours, e.g. 24 (or press Enter for #{default})."
      end
    end

    def ask_yes?(prompt)
      ask("#{prompt} [Y/n]").strip.downcase != "n"
    end

    def google_client(config, token)
      client_id, client_secret = config.client_credentials
      GoogleClient.new(client_id: client_id, client_secret: client_secret, refresh_token: token, calendar_id: config.calendar_id)
    end

    # Skip quietly if the previous run is still going.
    def with_lock(config)
      FileUtils.mkdir_p(config.state_dir, mode: 0o700)
      File.open(config.lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        return 0 unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        yield
      end
    end

    def local(iso)
      iso && Time.iso8601(iso).localtime.strftime("%Y-%m-%d %-l:%M%P")
    end
  end
end
