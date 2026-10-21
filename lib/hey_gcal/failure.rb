module HeyGcal
  # Turns an Error into what a person needs: a title, what it means for the
  # sync, and the steps that fix it.
  module Failure
    Explanation = Struct.new(:title, :impact, :actions, keyword_init: true)

    module_function

    def explain(error, config_path: Config::DEFAULT_PATH)
      cli = "hey-gcal"
      cfg = config_path == Config::DEFAULT_PATH ? "" : " --config #{config_path}"

      case error.kind
      when :config
        Explanation.new(
          title: "Config problem",
          impact: "Nothing was synced.",
          actions: ["Fix the problems listed above in #{config_path}.", "Run `#{cli} sync --dry-run#{cfg}` to check."]
        )
      when :hey_auth
        Explanation.new(
          title: "HEY CLI is signed out",
          impact: "Nothing was synced; Google was left as it was.",
          actions: ["Run `hey auth login` in Terminal and finish the sign-in.", "Confirm with `hey auth status`. The next scheduled run will catch up on its own."]
        )
      when :hey_cli
        Explanation.new(
          title: "HEY CLI failed or changed",
          impact: "Nothing was synced; Google was left as it was.",
          actions: [
            "Run `hey --version` and `hey event week --json` and check they work.",
            "If hey was moved or reinstalled, re-run `#{cli} install#{cfg}` so the job uses the new path.",
            "If hey answers but its JSON looks different, hey-gcal needs an update for the new format."
          ]
        )
      when :google_auth
        Explanation.new(
          title: "Google sign-in needs renewing",
          impact: "Nothing was synced.",
          actions: [
            "Run `#{cli} auth#{cfg}` and sign in with the Google account that owns or can edit the calendar.",
            "If this keeps happening about 7 days after each sign-in, the OAuth app is still in Testing: in Google Cloud Console > Google Auth Platform > Audience, click Publish app, then run auth again."
          ]
        )
      when :calendar_access
        Explanation.new(
          title: "Can't reach the Google calendar",
          impact: "Nothing was synced.",
          actions: [
            "Check the calendar still exists and that the signed-in Google account has \"Make changes to events\" on it.",
            "Check google.calendar_id in #{config_path} (Google Calendar > the calendar's settings > Integrate calendar > Calendar ID).",
            "If you signed in with a different Google account, run `#{cli} auth#{cfg}` again."
          ]
        )
      when :secret_store
        Explanation.new(
          title: "Can't read the saved Google sign-in",
          impact: "Nothing was synced.",
          actions: [
            "Make sure you are logged in to the computer (your keyring or Keychain unlocks at login).",
            "If the system asked whether hey-gcal may use the saved item, choose Allow / Always Allow.",
            "Run `#{cli} auth#{cfg}` to save a fresh sign-in."
          ]
        )
      when :scheduler
        Explanation.new(
          title: "Couldn't set up the background job",
          impact: "The sync won't run on its own until this is fixed.",
          actions: [
            "Read the error above; it comes from your system's scheduler (launchd, systemd/cron or Task Scheduler).",
            "Run `#{cli} install#{cfg}` again. Run `#{cli} sync#{cfg}` by hand meanwhile."
          ]
        )
      when :network
        Explanation.new(
          title: "Network or Google outage",
          impact: "This run was skipped; nothing was changed. It retries every few minutes.",
          actions: ["Check this computer's internet connection.", "Check https://www.google.com/appsstatus/dashboard/ for a Calendar outage.", "No action is needed if it clears up on its own."]
        )
      when :circuit_breaker
        Explanation.new(
          title: "Holding back a large delete",
          impact: "New and changed events were synced. Only the deletes listed above are on hold, and they stay on hold until you decide.",
          actions: [
            "Check HEY: were these events really cancelled or removed?",
            "If not, look for what hid them: a calendar switched off in HEY's web app (hey-gcal only sees calendars that are switched on), a change to hey.calendars or sync.skip_declined in #{config_path}, or `hey` signed in to a different account (`hey auth status`).",
            "If the deletes are right, run `#{cli} sync --allow-deletes#{cfg}` once to apply them."
          ]
        )
      when :partial
        Explanation.new(
          title: "Some events failed to sync",
          impact: "Everything else synced. The events listed above may be missing or out of date on Google.",
          actions: [
            "Read the error next to each event.",
            "Run `#{cli} sync#{cfg}` to retry, and check the log if it fails again."
          ]
        )
      when :meet_mismatch
        Explanation.new(
          title: "Google changed a Meet link",
          impact: "The events listed above show a Meet button Google made; the original link is the first line of each description.",
          actions: ["Join from the link in the description, not Google's button.", "Report this: hey-gcal needs a new way to keep Google's button off."]
        )
      else
        Explanation.new(
          title: "hey-gcal crashed",
          impact: "This run did not finish; some changes may not have been applied.",
          actions: ["Read the error and backtrace above, and the log.", "Run `#{cli} sync --dry-run#{cfg}` to reproduce it."]
        )
      end
    end

    # The plain-text report used for the Healthchecks email, the status
    # command and the log.
    def report(error, config:, consecutive: 1, since: nil)
      explanation = explain(error, config_path: config.path)
      lines = []
      lines << "hey-gcal (#{config.name}): #{explanation.title}"
      lines << ""
      lines << "What happened: #{error.message}"
      details_lines(error).each { |line| lines << line }
      lines << ""
      lines << "Effect: #{explanation.impact}"
      lines << "Failing since #{since || Time.now.utc.iso8601} (#{consecutive} run#{"s" unless consecutive == 1} in a row)."
      lines << ""
      lines << "What to do:"
      explanation.actions.each_with_index { |action, i| lines << "  #{i + 1}. #{action}" }
      lines << ""
      lines << "Status: hey-gcal status#{" --config #{config.path}" unless config.path == Config::DEFAULT_PATH}"
      lines << "Log: #{config.log_path}"
      lines.join("\n")
    end

    def details_lines(error)
      details = error.details
      return [] unless details.is_a?(Hash)

      lines = []
      Array(details[:deletes]).first(25).each { |d| lines << "  would delete: #{d}" }
      Array(details[:events]).first(25).each { |e| lines << "  #{e[:event]}: #{e[:message]}" }
      Array(details[:backtrace]).first(8).each { |b| lines << "  at #{b}" }
      lines
    end
  end
end
