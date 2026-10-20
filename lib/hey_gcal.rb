require "json"
require "time"
require "date"

# Background jobs (launchd, systemd, cron, Task Scheduler) often run with no
# locale, which makes Ruby read files and pipes as ASCII and choke on the
# first emoji or accented name. Everything hey-gcal reads (config, status,
# HEY's JSON, Google's JSON) is UTF-8.
Encoding.default_external = Encoding::UTF_8

module HeyGcal
  VERSION = "0.1.0"
  SCOPE = "https://www.googleapis.com/auth/calendar.events"
end

require_relative "hey_gcal/error"
require_relative "hey_gcal/platform"
require_relative "hey_gcal/time_zone"
require_relative "hey_gcal/config"
require_relative "hey_gcal/hey_client"
require_relative "hey_gcal/event_mapper"
require_relative "hey_gcal/http"
require_relative "hey_gcal/google_client"
require_relative "hey_gcal/syncer"
require_relative "hey_gcal/secret_store"
require_relative "hey_gcal/oauth"
require_relative "hey_gcal/failure"
require_relative "hey_gcal/reporter"
require_relative "hey_gcal/scheduler"
require_relative "hey_gcal/omarchy"
