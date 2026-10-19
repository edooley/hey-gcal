require "fileutils"
require "open3"

module HeyGcal
  # Where the Google refresh token is kept, using what each OS provides:
  #
  #   macOS    login Keychain              (/usr/bin/security)
  #   Linux    Secret Service / keyring    (secret-tool, from libsecret)
  #   Windows  DPAPI-encrypted file        (PowerShell; only your Windows login can decrypt it)
  #   any      plain file, mode 600        (fallback, or `"token_store": "file"`)
  #
  # Secrets always travel on stdin, never on a command line, so they never
  # show up in a process list.
  module SecretStore
    SERVICE = "hey-gcal"
    TOKEN_FORMAT = %r{\A[A-Za-z0-9._/~+-]+\z}
    STORES = %w[auto keychain secret-service dpapi file].freeze

    module_function

    def for(config)
      case config.token_store
      when "keychain" then MacKeychain.new(config)
      when "secret-service" then SecretService.new(config)
      when "dpapi" then WindowsDpapi.new(config)
      when "file" then PlainFile.new(config)
      else auto(config)
      end
    end

    def auto(config)
      case Platform.os
      when :macos then MacKeychain.new(config)
      when :windows then WindowsDpapi.new(config)
      else
        if Platform.which("secret-tool")
          WithFallback.new(SecretService.new(config), PlainFile.new(config))
        else
          PlainFile.new(config)
        end
      end
    end

    def check!(secret)
      return if secret.to_s.match?(TOKEN_FORMAT)

      raise Error.new(:secret_store, "Refusing to store a token with unexpected characters")
    end

    def missing(config)
      Error.new(:google_auth, "No Google sign-in is saved for \"#{config.name}\"")
    end

    class MacKeychain
      SECURITY = "/usr/bin/security"
      NOT_FOUND = 44

      def initialize(config)
        @config = config
      end

      def description = "the macOS login Keychain (service \"#{SERVICE}\", account \"#{account}\")"

      def write(secret)
        SecretStore.check!(secret)
        raise Error.new(:secret_store, "Unexpected characters in config name") unless account.match?(TOKEN_FORMAT)

        command = %(add-generic-password -U -s #{SERVICE} -a #{account} -l "hey-gcal (#{account})" -w #{secret}\n)
        _out, err, _status = Open3.capture3(SECURITY, "-i", stdin_data: command)
        # security -i exits 0 even when a command fails, so read it back.
        return if (read rescue nil) == secret

        raise Error.new(:secret_store, "Could not save the Google sign-in to the Keychain: #{err.strip}")
      end

      def read
        out, err, status = Open3.capture3(SECURITY, "find-generic-password", "-s", SERVICE, "-a", account, "-w")
        return out.strip if status.success?
        raise SecretStore.missing(@config) if status.exitstatus == NOT_FOUND

        raise Error.new(:secret_store, "The Keychain refused access (#{status.exitstatus}): #{err.strip}")
      end

      def delete
        Open3.capture3(SECURITY, "delete-generic-password", "-s", SERVICE, "-a", account)
      end

      private

      def account = @config.name
    end

    class SecretService
      def initialize(config)
        @config = config
      end

      def description = "your desktop keyring via Secret Service (service \"#{SERVICE}\", account \"#{@config.name}\")"

      def write(secret)
        SecretStore.check!(secret)
        _out, err, status = Open3.capture3("secret-tool", "store", "--label=hey-gcal (#{@config.name})", *attributes, stdin_data: secret)
        return if status.success?

        raise Error.new(:secret_store, "Could not save the Google sign-in to the keyring: #{err.strip}")
      end

      def read
        out, err, status = Open3.capture3("secret-tool", "lookup", *attributes)
        return out.strip if status.success? && !out.strip.empty?
        raise SecretStore.missing(@config) if err.strip.empty?

        raise Error.new(:secret_store, "The keyring refused access: #{err.strip}")
      end

      def delete
        Open3.capture3("secret-tool", "clear", *attributes)
      end

      private

      def attributes = ["service", SERVICE, "account", @config.name]
    end

    # Encrypted with the Windows Data Protection API under your Windows
    # login, so the file is useless to anyone else or on another machine.
    class WindowsDpapi
      ENCRYPT = "$s = [Console]::In.ReadLine(); ConvertTo-SecureString -String $s -AsPlainText -Force | ConvertFrom-SecureString"
      DECRYPT = "$b = [Console]::In.ReadLine(); $p = ConvertTo-SecureString -String $b; [System.Net.NetworkCredential]::new('', $p).Password"

      def initialize(config)
        @config = config
      end

      def path = File.join(Platform.config_dir, "#{@config.name}.token.dpapi")
      def description = "a file encrypted with your Windows login (#{path})"

      def write(secret)
        SecretStore.check!(secret)
        out, err, status = powershell(ENCRYPT, secret)
        raise Error.new(:secret_store, "Could not encrypt the Google sign-in: #{err.strip}") unless status.success? && !out.strip.empty?

        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, out.strip)
      end

      def read
        raise SecretStore.missing(@config) unless File.exist?(path)

        out, err, status = powershell(DECRYPT, File.read(path).strip)
        return out.strip if status.success? && !out.strip.empty?

        raise Error.new(:secret_store, "Could not decrypt the saved Google sign-in (is this the same Windows user?): #{err.strip}")
      end

      def delete
        File.delete(path) if File.exist?(path)
      end

      private

      def powershell(script, input)
        Open3.capture3("powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script, stdin_data: "#{input}\n")
      rescue Errno::ENOENT
        raise Error.new(:secret_store, "PowerShell (powershell.exe) was not found")
      end
    end

    # Readable only by your user. Protected by your account and disk
    # encryption, not by a keyring.
    class PlainFile
      def initialize(config)
        @config = config
      end

      def path = File.join(Platform.config_dir, "#{@config.name}.token")
      def description = "a file readable only by you (#{path})"

      def write(secret)
        SecretStore.check!(secret)
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        File.open(path, "w", 0o600) { |f| f.write(secret) }
        File.chmod(0o600, path)
      end

      def read
        raise SecretStore.missing(@config) unless File.exist?(path)

        File.read(path).strip
      end

      def delete
        File.delete(path) if File.exist?(path)
      end
    end

    # Linux: prefer the keyring, but fall back to a private file where there
    # is no Secret Service running (a minimal or headless desktop).
    class WithFallback
      attr_reader :description

      def initialize(primary, fallback)
        @primary = primary
        @fallback = fallback
        @description = primary.description
      end

      def write(secret)
        @primary.write(secret)
        @fallback.delete
      rescue Error => e
        raise unless e.kind == :secret_store

        warn "Keyring unavailable (#{e.message}); saving to #{@fallback.description} instead."
        @fallback.write(secret)
        @description = @fallback.description
      end

      def read
        @primary.read
      rescue Error
        raise unless File.exist?(@fallback.path)

        @fallback.read
      end

      def delete
        @primary.delete
        @fallback.delete
      end
    end
  end
end
