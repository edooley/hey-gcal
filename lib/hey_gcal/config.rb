require "fileutils"

module HeyGcal
  class Config
    DEFAULT_PATH = File.join(Platform.config_dir, "config.json")
    CALENDAR_PLACEHOLDER = "PASTE-YOUR-GOOGLE-CALENDAR-ID"
    NAME_FORMAT = /\A[a-z0-9][a-z0-9_-]{0,40}\z/i
    ACCOUNT_FORMAT = /\A[A-Za-z0-9_-]+\z/

    TEMPLATE = {
      "name" => "default",
      "google" => {
        "client_secret_path" => "client_secret.json",
        "calendar_id" => CALENDAR_PLACEHOLDER,
        "token_store" => "auto"
      },
      "hey" => {
        "bin" => nil,
        "account" => nil,
        "calendars" => [],
        "time_zone" => nil
      },
      "sync" => {
        "past_days" => 7,
        "future_days" => 90,
        "skip_declined" => true,
        "detail" => "full",
        "title_prefix" => "",
        "max_deletes" => 5,
        "max_delete_ratio" => 0.3
      },
      "healthchecks_url" => nil,
      "stale_after_hours" => 24
    }.freeze

    attr_reader :path, :data

    def self.init(path = DEFAULT_PATH)
      path = File.expand_path(path)
      return false if File.exist?(path)

      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.write(path, JSON.pretty_generate(TEMPLATE) + "\n")
      File.chmod(0o600, path)
      true
    end

    # Changes the raw config JSON in place (used by `setup`).
    def self.update(path)
      data = JSON.parse(File.read(path))
      yield data
      File.write(path, JSON.pretty_generate(data) + "\n")
      File.chmod(0o600, path)
    end

    # require_calendar: false lets `auth` run before a calendar ID is chosen.
    def self.load(path = DEFAULT_PATH, require_calendar: true)
      path = File.expand_path(path)
      raise Error.new(:config, "No config at #{path}. Run `hey-gcal init` to create one.") unless File.exist?(path)

      data = begin
        JSON.parse(File.read(path))
      rescue JSON::ParserError => e
        raise Error.new(:config, "#{path} is not valid JSON: #{e.message}")
      end

      new(path, data).tap { |config| config.validate!(require_calendar: require_calendar) }
    end

    def initialize(path, data)
      @path = path
      @data = deep_merge(TEMPLATE, data)
    end

    def validate!(require_calendar: true)
      problems = []
      problems << "name must be letters, digits, - or _ (got #{name.inspect})" unless name.to_s.match?(NAME_FORMAT)
      if require_calendar && (calendar_id.to_s.strip.empty? || calendar_id == CALENDAR_PLACEHOLDER)
        problems << "google.calendar_id is not set"
      end
      problems << "hey.account must be an account id from `hey account list`" if hey_account && !hey_account.to_s.match?(ACCOUNT_FORMAT)
      problems << "hey.calendars must be a list" unless hey_calendars.is_a?(Array)
      problems << "hey.time_zone #{hey_time_zone.inspect} isn't a time zone this computer knows (use a name like America/Chicago)" if hey_time_zone && !TimeZone.valid?(hey_time_zone)
      problems << "google.token_store must be one of #{SecretStore::STORES.join(", ")}" unless SecretStore::STORES.include?(token_store)
      problems << "sync.detail must be \"full\" or \"minimal\"" unless %w[full minimal].include?(detail)
      problems << "sync.title_prefix must be text (up to 40 characters)" unless data["sync"]["title_prefix"].is_a?(String) && data["sync"]["title_prefix"].length <= 40
      %w[past_days future_days max_deletes].each do |key|
        value = data["sync"][key]
        problems << "sync.#{key} must be a whole number >= 0" unless value.is_a?(Integer) && value >= 0
      end
      problems << "sync.max_delete_ratio must be between 0 and 1" unless max_delete_ratio.is_a?(Numeric) && max_delete_ratio.between?(0, 1)
      problems << "stale_after_hours must be a number of hours above 0" unless stale_after_hours.is_a?(Numeric) && stale_after_hours.positive?
      if healthchecks_url && !healthchecks_url.match?(%r{\Ahttps://[A-Za-z0-9.-]+(:\d+)?/[A-Za-z0-9/_-]+\z})
        problems << "healthchecks_url must be an https ping URL"
      end
      return if problems.empty?

      raise Error.new(:config, "#{path} has problems:\n  - #{problems.join("\n  - ")}")
    end

    def name = data["name"]
    def calendar_id = data["google"]["calendar_id"]
    # Relative paths are relative to the config file's folder.
    def client_secret_path = File.expand_path(data["google"]["client_secret_path"], File.dirname(path))
    def token_store = data["google"]["token_store"]
    def hey_bin = data["hey"]["bin"]
    def hey_account = data["hey"]["account"]
    def hey_calendars = data["hey"]["calendars"]
    def hey_time_zone = data["hey"]["time_zone"]
    def past_days = data["sync"]["past_days"]
    def future_days = data["sync"]["future_days"]
    def skip_declined? = data["sync"]["skip_declined"] != false
    def detail = data["sync"]["detail"]
    def title_prefix = data["sync"]["title_prefix"].to_s
    def max_deletes = data["sync"]["max_deletes"]
    def max_delete_ratio = data["sync"]["max_delete_ratio"]
    def healthchecks_url = data["healthchecks_url"]
    # How long without a successful sync before `status` and the Omarchy bar
    # call it a problem. Set it to your Healthchecks.io Grace Time so the
    # email and the local warnings agree.
    def stale_after_hours = data["stale_after_hours"]
    def stale_after_seconds = (stale_after_hours * 3600).to_i

    def state_dir = Platform.state_dir
    def state_path = File.join(state_dir, "#{name}.json")
    def lock_path = File.join(state_dir, "#{name}.lock")
    def log_dir = Platform.log_dir
    def log_path = File.join(log_dir, "#{name}.log")

    def client_credentials
      unless File.exist?(client_secret_path)
        raise Error.new(:config, "Google OAuth client file not found at #{client_secret_path}")
      end

      json = JSON.parse(File.read(client_secret_path))
      creds = json["installed"] || json["web"] || {}
      unless creds["client_id"] && creds["client_secret"]
        raise Error.new(:config, "#{client_secret_path} is not a Google OAuth client file (expected a Desktop app client)")
      end

      [creds["client_id"], creds["client_secret"]]
    rescue JSON::ParserError
      raise Error.new(:config, "#{client_secret_path} is not valid JSON")
    end

    private

    def deep_merge(base, override)
      base.merge(override) do |_key, old, new|
        old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge(old, new) : new
      end
    end
  end
end
