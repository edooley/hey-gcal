require "base64"
require "digest"
require "openssl"
require "securerandom"
require "socket"

module HeyGcal
  # Google's installed-app OAuth flow with a loopback redirect: listens on
  # 127.0.0.1 only, on a random port, checks a random state, uses PKCE, and
  # takes exactly one callback before shutting down.
  module OAuth
    AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
    TOKEN_URL = "https://oauth2.googleapis.com/token"
    WAIT = 300

    module_function

    # Returns a refresh token. `open` receives the URL to show the user.
    def authorize(client_id:, client_secret:, scope: SCOPE, open: ->(url) { Platform.open_url(url) })
      server = TCPServer.new("127.0.0.1", 0)
      redirect_uri = "http://127.0.0.1:#{server.addr[1]}"
      verifier = SecureRandom.urlsafe_base64(64)
      state = SecureRandom.hex(16)

      url = "#{AUTH_URL}?" + URI.encode_www_form(
        "client_id" => client_id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => scope,
        "access_type" => "offline",
        "prompt" => "consent",
        "state" => state,
        "code_challenge" => Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false),
        "code_challenge_method" => "S256"
      )
      open.call(url)

      params = await_callback(server)
      unless params["state"] && OpenSSL.secure_compare(params["state"], state)
        raise Error.new(:google_auth, "The sign-in callback had the wrong state; try again")
      end
      raise Error.new(:google_auth, "Google sign-in was not completed: #{params["error"]}") if params["error"]
      raise Error.new(:google_auth, "Google sent no authorization code") unless params["code"]

      exchange(params["code"], verifier, redirect_uri, client_id, client_secret)
    ensure
      server&.close
    end

    def await_callback(server)
      unless IO.select([server], nil, nil, WAIT)
        raise Error.new(:google_auth, "Timed out after #{WAIT / 60} minutes waiting for the Google sign-in")
      end

      client = server.accept
      request_line = client.gets.to_s
      target = request_line.split(" ")[1].to_s
      params = URI.decode_www_form(URI.parse(target).query.to_s).to_h
      message = params["code"] ? "Signed in. You can close this tab and return to the terminal." : "Sign-in did not complete. Return to the terminal."
      client.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\nhey-gcal: #{message}\n")
      client.close
      params
    rescue URI::InvalidURIError
      {}
    end

    def exchange(code, verifier, redirect_uri, client_id, client_secret)
      form = URI.encode_www_form(
        "code" => code, "code_verifier" => verifier, "redirect_uri" => redirect_uri,
        "client_id" => client_id, "client_secret" => client_secret, "grant_type" => "authorization_code"
      )
      response = Http.request(:post, TOKEN_URL, headers: { "Content-Type" => "application/x-www-form-urlencoded" }, body: form)
      json = response.json
      return json["refresh_token"] if response.status == 200 && json["refresh_token"]

      if response.status == 200
        raise Error.new(:google_auth, "Google returned no refresh token. Remove the app at https://myaccount.google.com/permissions and run auth again")
      end

      raise Error.new(:google_auth, "Token exchange failed: #{json["error"]} #{json["error_description"]}")
    end
  end
end
