require "net/http"
require "openssl"
require "uri"

module HeyGcal
  # The one place hey-gcal opens a network connection: HTTPS only, certificate
  # verification on (Net::HTTP's default), to an allowlisted host.
  module Http
    GOOGLE_HOSTS = %w[oauth2.googleapis.com www.googleapis.com].freeze
    NETWORK_ERRORS = [
      SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
      Errno::ENETUNREACH, Errno::ETIMEDOUT, EOFError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse
    ].freeze

    Response = Struct.new(:status, :body) do
      def json
        body.to_s.empty? ? {} : JSON.parse(body)
      rescue JSON::ParserError
        { "raw" => body.to_s[0, 300] }
      end
    end

    module_function

    def request(method, url, headers: {}, body: nil, allowed_hosts: GOOGLE_HOSTS, timeout: 30)
      uri = URI.parse(url)
      unless uri.is_a?(URI::HTTPS) && allowed_hosts.include?(uri.host)
        raise ArgumentError, "refusing to contact #{uri.host.inspect}"
      end

      request = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
      headers.each { |k, v| request[k] = v }
      request.body = body if body
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: timeout) do |http|
        http.request(request)
      end
      Response.new(response.code.to_i, response.body)
    rescue *NETWORK_ERRORS => e
      raise Error.new(:network, "Could not reach #{uri&.host}: #{e.class}: #{e.message}")
    end
  end
end
