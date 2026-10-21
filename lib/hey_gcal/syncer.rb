module HeyGcal
  # One sync run: read HEY, read what we previously wrote to Google, and make
  # Google match. Google holds the mapping (hey_key in each event's private
  # extended properties), so there is no local database.
  class Syncer
    DAY = 86_400
    # Systemic errors stop the run; anything else is pinned to the one event.
    SYSTEMIC = %i[network google_auth calendar_access secret_store hey_auth hey_cli].freeze

    # held: deletes the safety check is holding back (see hold_deletes);
    # hold_reason says why.
    Plan = Struct.new(:inserts, :updates, :deletes, :unchanged, :held, :hold_reason, keyword_init: true) do
      def writes = inserts.size + updates.size + deletes.size
      def held? = !held.to_a.empty?
    end

    Result = Struct.new(:plan, :hey_count, :inserted, :updated, :deleted, :warnings, :event_errors, keyword_init: true) do
      def summary
        "+#{inserted} ~#{updated} -#{deleted} (#{plan.unchanged} unchanged, #{hey_count} HEY events in window)"
      end
    end

    def initialize(hey:, google:, config:, log: ->(_line) {}, today: Date.today, dry_run: false, allow_deletes: false)
      @hey = hey
      @google = google
      @config = config
      @log = log
      @today = today
      @dry_run = dry_run
      @allow_deletes = allow_deletes
      @warnings = []
      @blocked = []
      @custom_conference = nil
    end

    def run
      window_start = midnight(@today - @config.past_days)
      window_end = midnight(@today + @config.future_days + 1)

      hey_events = @hey.events(@today - @config.past_days, @today + @config.future_days)
      desired = hey_events.select { |_key, event| EventMapper.overlaps?(event, window_start, window_end) }
      # Look a little wider on Google so an event at the window's edge is
      # still found and never inserted twice.
      marked = @google.list_managed(window_start - 2 * DAY, window_end + 2 * DAY)
      managed = marked.select { |e| ours?(e) }
      # Keys carried by marked events we don't consider ours. Never insert
      # over one of them: if the ownership check were ever wrong again, the
      # cost is a skipped event and an alert, not a new copy every run.
      foreign_keys = (marked - managed).map { |e| e.dig("extendedProperties", "private", "hey_key") }.compact

      plan = plan(desired, hey_events, managed, window_start, window_end, foreign_keys)
      hold_deletes(plan, hey_events, managed)

      result = Result.new(plan: plan, hey_count: desired.size, inserted: 0, updated: 0, deleted: 0, warnings: @warnings, event_errors: @blocked.dup)
      return result if @dry_run

      execute(plan, result)
      result
    end

    private

    # Carries our private marker and belongs to this calendar. Google sets
    # creator.self on events in your primary calendar, but on a secondary or
    # shared calendar it leaves creator.self out and sets organizer.self (the
    # calendar organizes its own events), so either one counts.
    def ours?(google_event)
      google_event.dig("extendedProperties", "private", "hey_sync") == "1" &&
        google_event.dig("extendedProperties", "private", "hey_key") &&
        (google_event.dig("creator", "self") == true || google_event.dig("organizer", "self") == true)
    end

    def plan(desired, hey_events, managed, window_start, window_end, foreign_keys = [])
      by_key = {}
      duplicates = []
      managed.each do |google_event|
        key = google_event.dig("extendedProperties", "private", "hey_key")
        by_key.key?(key) ? duplicates << google_event : by_key[key] = google_event
      end

      inserts = []
      updates = []
      unchanged = 0
      desired.each do |key, event|
        body = EventMapper.build(event, detail: @config.detail, prefix: @config.title_prefix)
        existing = by_key[key]
        if existing.nil? && foreign_keys.include?(key)
          @blocked << { event: describe(event), kind: :google_request,
                        message: "A copy with this HEY key exists on the calendar but doesn't look like hey-gcal's own (it isn't organized by the calendar or created by you), so no new copy was made" }
        elsif existing.nil?
          inserts << { event: event, body: body }
        elsif EventMapper.hash_of(existing) != EventMapper.hash_of(body)
          updates << { event: event, body: body, google: existing }
        else
          unchanged += 1
        end
      end

      gone = by_key.reject { |key, google_event| hey_events.key?(key) || !starts_within?(google_event, window_start, window_end) }
      # Extra copies of an event HEY still has are our own cleanup, never held.
      deletes = gone.values.map { |google_event| { google: google_event } } +
                duplicates.map { |google_event| { google: google_event, duplicate: true } }

      Plan.new(inserts: inserts, updates: updates, deletes: deletes, unchanged: unchanged, held: [])
    end

    # The safety check on deletes. Every run deletes what is missing from
    # HEY's answer, so an answer that looks fine but isn't (a calendar hidden
    # in HEY, a config typo, `hey` signed in to another account, a format
    # change) would empty the Google calendar. Ordinary changes (a series
    # ending, a declined meeting, a cleared week) must not trip it, so it
    # counts a repeating event's days as one and only stops when the answer
    # looks like a disaster:
    #
    #   - HEY returned no events at all while synced copies exist, or
    #   - more than max_delete_ratio of the synced copies would go, spread
    #     over more than max_deletes separate events (a series counts once).
    #
    # Even then only those deletes wait; new and changed events still sync.
    def hold_deletes(plan, hey_events, managed)
      gone = plan.deletes.reject { |d| d[:duplicate] }
      return if @allow_deletes || gone.empty?

      series = gone.map { |d| series_key(d[:google].dig("extendedProperties", "private", "hey_key")) }.uniq
      reason =
        if hey_events.empty?
          "HEY returned no events at all, but #{managed.size} synced copies exist on Google"
        elsif series.size > @config.max_deletes && gone.size > @config.max_delete_ratio * managed.size
          "#{gone.size} of #{managed.size} synced copies (#{series.size} separate events) would be deleted at once, " \
            "more than #{(@config.max_delete_ratio * 100).round}% across more than #{@config.max_deletes} events"
        end
      return unless reason

      plan.held = gone
      plan.deletes -= gone
      plan.hold_reason = reason
    end

    # "<series>_<YYYY-MM-DD>" -> "<series>": every day of a repeating event
    # counts as one event for the safety check.
    def series_key(key)
      key.to_s.sub(/_\d{4}-\d{2}-\d{2}\z/, "")
    end

    def execute(plan, result)
      plan.inserts.each do |item|
        each_event(result, item[:event]) do
          write(nil, item[:body], EventMapper.meet_link(item[:event]))
          result.inserted += 1
          @log.call("inserted #{describe(item[:event])}")
        end
      end

      plan.updates.each do |item|
        each_event(result, item[:event]) do
          write(item[:google]["id"], item[:body], EventMapper.meet_link(item[:event]))
          result.updated += 1
          @log.call("updated #{describe(item[:event])}")
        end
      end

      plan.deletes.each do |item|
        each_event(result, nil, item[:google]) do
          @google.delete(item[:google]["id"])
          result.deleted += 1
          @log.call("deleted #{describe_google(item[:google])}")
        end
      end
    end

    def each_event(result, event, google_event = nil)
      yield
    rescue Error => e
      raise if SYSTEMIC.include?(e.kind)

      label = event ? describe(event) : describe_google(google_event)
      result.event_errors << { event: label, kind: e.kind, message: e.message }
      @log.call("FAILED #{label}: #{e.message}")
    end

    # Writes the event and makes sure Google shows the original Meet link, or
    # no Meet link at all, never one Google made up.
    def write(google_id, body, link)
      if link && @custom_conference != false
        begin
          saved = save(google_id, body.merge("conferenceData" => EventMapper.conference_data(link)))
          if EventMapper.google_join_link(saved) == link
            @custom_conference = true
            return saved
          end
          warn_once("Google swapped the Meet link when it was set as conference data; using the description and location only.")
          @custom_conference = false
          google_id = saved["id"]
        rescue Error => e
          raise unless e.kind == :google_request

          warn_once("Google would not take the original Meet link as conference data (#{e.message}); using the description and location only.")
          @custom_conference = false
        end
      end

      saved = save(google_id, body)
      actual = EventMapper.google_join_link(saved)
      if actual && actual != link
        raise Error.new(:meet_mismatch, "Google attached its own Meet link and would not remove it; the original link is in the description")
      end

      saved
    end

    def save(google_id, body)
      return @google.insert(body) unless google_id

      @google.update(google_id, body)
    rescue Error => e
      # Deleted on Google by hand: put it back.
      raise unless google_id && e.details.is_a?(Hash) && [404, 410].include?(e.details[:status])

      @google.insert(body)
    end

    def warn_once(message)
      @warnings << message unless @warnings.include?(message)
    end

    def starts_within?(google_event, window_start, window_end)
      start = google_event.dig("start", "dateTime") || google_event.dig("start", "date")
      return false unless start

      time = start.length == 10 ? midnight(Date.parse(start)) : Time.iso8601(start)
      time >= window_start && time < window_end
    end

    def midnight(date)
      Time.utc(date.year, date.month, date.day)
    end

    def describe(event)
      "\"#{event["title"]}\" #{event["starts_at"]} [#{EventMapper.key(event)}]"
    end

    def describe_google(google_event) = self.class.describe_google(google_event)

    def self.describe_google(google_event)
      start = google_event.dig("start", "dateTime") || google_event.dig("start", "date")
      "\"#{google_event["summary"]}\" #{start} [#{google_event.dig("extendedProperties", "private", "hey_key")}]"
    end
  end
end
