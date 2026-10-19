module HeyGcal
  # Google Calendar v3, limited to one calendar and the events.* calls the sync
  # needs. Every write passes sendUpdates=none so nobody is ever emailed.
  class GoogleClient
    API = "https://www.googleapis.com/calendar/v3"
    TOKEN_URL = "https://oauth2.googleapis.com/token"

    attr_reader :calendar_id

    def initialize(client_id:, client_secret:, refresh_token:, calendar_id:)
      @client_id = client_id
      @client_secret = client_secret
      @refresh_token = refresh_token
      @calendar_id = calendar_id
      @access_token = nil
    end

    # Events this tool created, overlapping [time_min, time_max).
    def list_managed(time_min, time_max)
      events = []
      page = nil
      loop do
        query = {
          "privateExtendedProperty" => "hey_sync=1",
          "singleEvents" => "true",
          "showDeleted" => "false",
          "maxResults" => "2500",
          "timeMin" => time_min.utc.iso8601,
          "timeMax" => time_max.utc.iso8601
        }
        query["pageToken"] = page if page
        json = call(:get, events_path, query: query)
        events.concat(Array(json["items"]))
        page = json["nextPageToken"]
        break unless page
      end
      events
    end

    # Proves the token can read the calendar.
    def check_access
      call(:get, events_path, query: { "maxResults" => "1" })
      true
    end

    def insert(body)
      call(:post, events_path, query: write_query, body: body)
    end

    def update(event_id, body)
      call(:put, "#{events_path}/#{esc(event_id)}", query: write_query, body: body)
    end

    def delete(event_id)
      call(:delete, "#{events_path}/#{esc(event_id)}", query: { "sendUpdates" => "none" })
    rescue Error => e
      raise unless e.details.is_a?(Hash) && [404, 410].include?(e.details[:status])
    end

    private

    # conferenceDataVersion=1 makes Google honor exactly the conferenceData we
    # send (ours, or none), so it never adds a Meet of its own.
    def write_query
      { "sendUpdates" => "none", "conferenceDataVersion" => "1" }
    end

    def events_path
      "/calendars/#{esc(calendar_id)}/events"
    end

    def esc(value)
      URI.encode_www_form_component(value.to_s)
    end

    def call(method, path, query: {}, body: nil, retried: false)
      url = "#{API}#{path}"
      url += "?#{URI.encode_www_form(query)}" unless query.empty?
      headers = { "Authorization" => "Bearer #{access_token}", "Accept" => "application/json" }
      headers["Content-Type"] = "application/json" if body
      response = Http.request(method, url, headers: headers, body: body && JSON.generate(body))

      return response.json if response.status.between?(200, 299)

      if response.status == 401 && !retried
        @access_token = nil
        return call(method, path, query: query, body: body, retried: true)
      end

      raise api_error(response)
    end

    def api_error(response)
      json = response.json
      message = json.dig("error", "message") || json["raw"] || "HTTP #{response.status}"
      reasons = Array(json.dig("error", "errors")).map { |e| e["reason"] }
      details = { status: response.status, reasons: reasons }

      kind =
        if response.status == 429 || response.status >= 500 || (reasons & %w[rateLimitExceeded userRateLimitExceeded quotaExceeded]).any?
          :network
        elsif response.status == 401
          :google_auth
        elsif [403, 404].include?(response.status)
          :calendar_access
        else
          :google_request
        end
      Error.new(kind, "Google Calendar answered #{response.status}: #{message}", details: details)
    end

    def access_token
      @access_token ||= begin
        form = URI.encode_www_form(
          "client_id" => @client_id, "client_secret" => @client_secret,
          "refresh_token" => @refresh_token, "grant_type" => "refresh_token"
        )
        response = Http.request(:post, TOKEN_URL, headers: { "Content-Type" => "application/x-www-form-urlencoded" }, body: form)
        json = response.json
        if response.status == 200 && json["access_token"]
          json["access_token"]
        elsif json["error"] == "invalid_grant" || json["error"] == "invalid_client" || json["error"] == "unauthorized_client"
          raise Error.new(:google_auth, "Google refused the saved sign-in (#{json["error"]}: #{json["error_description"]})")
        elsif response.status >= 500
          raise Error.new(:network, "Google's token service answered #{response.status}")
        else
          raise Error.new(:google_auth, "Could not refresh the Google sign-in: HTTP #{response.status} #{json["error"]}")
        end
      end
    end
  end
end
