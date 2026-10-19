module HeyGcal
  # Every failure the sync knows how to explain carries a kind. Failure maps
  # the kind to a title and the steps that fix it.
  #
  #   :config           config file missing or invalid
  #   :hey_auth         the hey CLI is not logged in
  #   :hey_cli          hey missing, failing, or answering in an unexpected shape
  #   :google_auth      no refresh token, or Google revoked it
  #   :calendar_access  the target calendar is gone or not writable
  #   :google_request   Google rejected a request (400)
  #   :secret_store     the OS keyring / token store refused access
  #   :scheduler        installing or removing the background job failed
  #   :network          timeouts, DNS, 429 and 5xx: usually transient
  #   :circuit_breaker  the run wanted to delete more than is safe
  #   :meet_mismatch    Google attached a Meet link other than the original
  #   :partial          some event writes failed
  #   :crash            anything unexpected
  class Error < StandardError
    attr_reader :kind, :details

    def initialize(kind, message, details: nil)
      super(message)
      @kind = kind
      @details = details
    end

    def transient?
      kind == :network
    end
  end
end
