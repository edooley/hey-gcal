require "erb"
require "fileutils"
require "open3"
require "shellwords"
require "tmpdir"

module HeyGcal
  # Runs `hey-gcal sync` every few minutes while you are logged in, using the
  # scheduler each OS already has:
  #
  #   macOS    launchd LaunchAgent    ~/Library/LaunchAgents/hey-gcal.<name>.plist
  #   Linux    systemd user timer     ~/.config/systemd/user/hey-gcal-<name>.{service,timer}
  #            (or a crontab line where there is no systemd user session)
  #   Windows  Task Scheduler task    "hey-gcal-<name>"
  #
  # Every path is resolved at install time and written into the job, so the
  # job never depends on your shell's PATH or setup.
  module Scheduler
    BIN = File.expand_path("../../bin/hey-gcal", __dir__)

    Job = Struct.new(:name, :argv, :interval, :log_path, keyword_init: true) do
      def minutes = [(interval / 60.0).round, 1].max
    end

    module_function

    def for(_config = nil)
      case Platform.os
      when :macos then Launchd.new
      when :windows then TaskScheduler.new
      else systemd_user? ? Systemd.new : Cron.new
      end
    end

    def job(config, interval:, hey:)
      Job.new(
        name: config.name,
        argv: [Platform.background_ruby, BIN, "sync", "--config", config.path, "--hey-bin", hey],
        interval: Integer(interval),
        log_path: File.join(config.log_dir, "#{config.name}.scheduler.log")
      )
    end

    def systemd_user?
      return false unless Platform.which("systemctl")

      _out, _err, status = Open3.capture3("systemctl", "--user", "show-environment")
      status.success?
    rescue SystemCallError
      false
    end

    def run(*argv, stdin: nil)
      out, err, status = Open3.capture3(*argv, stdin_data: stdin.to_s)
      [out, err, status.success?]
    rescue SystemCallError => e
      ["", e.message, false]
    end

    class Launchd
      def label(name) = "hey-gcal.#{name}"
      def path(name) = File.expand_path("~/Library/LaunchAgents/#{label(name)}.plist")
      def domain = "gui/#{Process.uid}"
      def description(name) = "launchd agent #{path(name)}"

      def definition(job)
        h = ->(value) { ERB::Util.html_escape(value.to_s) }
        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0">
          <dict>
            <key>Label</key>
            <string>#{h[label(job.name)]}</string>
            <key>ProgramArguments</key>
            <array>
          #{job.argv.map { |a| "    <string>#{h[a]}</string>" }.join("\n")}
            </array>
            <key>EnvironmentVariables</key>
            <dict>
              <key>PATH</key>
              <string>/usr/bin:/bin:/usr/sbin:/sbin</string>
            </dict>
            <key>StartInterval</key>
            <integer>#{job.interval}</integer>
            <key>RunAtLoad</key>
            <true/>
            <key>ProcessType</key>
            <string>Background</string>
            <key>StandardOutPath</key>
            <string>#{h[job.log_path]}</string>
            <key>StandardErrorPath</key>
            <string>#{h[job.log_path]}</string>
          </dict>
          </plist>
        XML
      end

      def install(job)
        FileUtils.mkdir_p(File.dirname(job.log_path))
        FileUtils.mkdir_p(File.dirname(path(job.name)))
        File.write(path(job.name), definition(job))
        File.chmod(0o644, path(job.name))
        Scheduler.run("/bin/launchctl", "bootout", "#{domain}/#{label(job.name)}")
        _out, err, ok = Scheduler.run("/bin/launchctl", "bootstrap", domain, path(job.name))
        raise Error.new(:scheduler, "launchctl bootstrap failed: #{err.strip}") unless ok
      end

      def uninstall(name)
        Scheduler.run("/bin/launchctl", "bootout", "#{domain}/#{label(name)}")
        File.delete(path(name)) if File.exist?(path(name))
      end

      def status(name)
        out, _err, ok = Scheduler.run("/bin/launchctl", "print", "#{domain}/#{label(name)}")
        return { installed: false } unless ok

        { installed: true, summary: "launchd, #{out[/^\s*state = (.+)$/, 1]}, every #{out[/run interval = (.+)$/, 1] || "?"}, last exit #{out[/^\s*last exit code = (.+)$/, 1] || "n/a"}" }
      end
    end

    class Systemd
      def unit(name) = "hey-gcal-#{name}"
      def dir = File.join(Platform.env_dir("XDG_CONFIG_HOME", "~/.config"), "systemd", "user")
      def description(name) = "systemd user timer #{File.join(dir, "#{unit(name)}.timer")}"

      # systemd's own quoting: double quotes, with \ " % $ escaped.
      def exec_line(argv)
        argv.map { |a| %("#{a.gsub("\\", "\\\\\\\\").gsub('"', '\\"').gsub("%", "%%").gsub("$", "$$")}") }.join(" ")
      end

      def service(job)
        <<~UNIT
          [Unit]
          Description=hey-gcal sync (#{job.name})

          [Service]
          Type=oneshot
          Environment=HEY_NONINTERACTIVE=1
          ExecStart=#{exec_line(job.argv)}
        UNIT
      end

      def timer(job)
        <<~UNIT
          [Unit]
          Description=Run hey-gcal sync (#{job.name}) every #{job.interval}s

          [Timer]
          OnActiveSec=15s
          OnUnitActiveSec=#{job.interval}s
          AccuracySec=30s

          [Install]
          WantedBy=timers.target
        UNIT
      end

      def install(job)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "#{unit(job.name)}.service"), service(job))
        File.write(File.join(dir, "#{unit(job.name)}.timer"), timer(job))
        Scheduler.run("systemctl", "--user", "daemon-reload")
        _out, err, ok = Scheduler.run("systemctl", "--user", "enable", "--now", "#{unit(job.name)}.timer")
        raise Error.new(:scheduler, "systemctl --user enable failed: #{err.strip}") unless ok
      end

      def uninstall(name)
        Scheduler.run("systemctl", "--user", "disable", "--now", "#{unit(name)}.timer")
        %w[service timer].each do |ext|
          file = File.join(dir, "#{unit(name)}.#{ext}")
          File.delete(file) if File.exist?(file)
        end
        Scheduler.run("systemctl", "--user", "daemon-reload")
      end

      def status(name)
        active, _err, _ok = Scheduler.run("systemctl", "--user", "is-active", "#{unit(name)}.timer")
        return { installed: false } unless File.exist?(File.join(dir, "#{unit(name)}.timer"))

        result, _err, _ok = Scheduler.run("systemctl", "--user", "show", "#{unit(name)}.service", "-p", "Result", "--value")
        { installed: true, summary: "systemd timer #{active.strip}, last result #{result.strip.empty? ? "n/a" : result.strip}" }
      end
    end

    class Cron
      def marker(name) = "# hey-gcal:#{name}"
      def description(name) = "a crontab line marked \"#{marker(name)}\""

      def line(job)
        schedule = job.minutes < 60 ? "*/#{job.minutes} * * * *" : "0 */#{[job.minutes / 60, 23].min} * * *"
        command = job.argv.map { |a| Shellwords.escape(a) }.join(" ")
        "#{schedule} HEY_NONINTERACTIVE=1 #{command} >> #{Shellwords.escape(job.log_path)} 2>&1 #{marker(job.name)}"
      end

      def install(job)
        raise Error.new(:scheduler, "Neither a systemd user session nor crontab is available") unless Platform.which("crontab")

        FileUtils.mkdir_p(File.dirname(job.log_path))
        write(lines_without(job.name) + [line(job)])
      end

      def uninstall(name)
        write(lines_without(name)) if Platform.which("crontab")
      end

      def status(name)
        installed = Platform.which("crontab") && current.any? { |l| l.end_with?(marker(name)) }
        installed ? { installed: true, summary: "crontab" } : { installed: false }
      end

      private

      def current
        out, _err, ok = Scheduler.run("crontab", "-l")
        ok ? out.lines.map(&:chomp) : []
      end

      def lines_without(name)
        current.reject { |l| l.end_with?(marker(name)) }
      end

      def write(lines)
        _out, err, ok = Scheduler.run("crontab", "-", stdin: lines.join("\n") + "\n")
        raise Error.new(:scheduler, "crontab update failed: #{err.strip}") unless ok
      end
    end

    class TaskScheduler
      def task(name) = "hey-gcal-#{name}"
      def description(name) = "Task Scheduler task \"#{task(name)}\""

      # Windows command-line quoting for one argument.
      def quote(arg)
        %("#{arg.to_s.gsub(/(\\*)"/) { "#{$1}#{$1}\\\"" }.sub(/(\\+)\z/) { "#{$1}#{$1}" }}")
      end

      def definition(job)
        h = ->(value) { ERB::Util.html_escape(value.to_s) }
        user = ENV["USERNAME"] && [ENV["USERDOMAIN"], ENV["USERNAME"]].compact.join("\\")
        <<~XML
          <?xml version="1.0" encoding="UTF-16"?>
          <Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
            <RegistrationInfo>
              <Description>hey-gcal: one-way sync from HEY Calendar to Google Calendar (#{h[job.name]})</Description>
            </RegistrationInfo>
            <Triggers>
              <TimeTrigger>
                <Repetition>
                  <Interval>PT#{job.minutes}M</Interval>
                  <StopAtDurationEnd>false</StopAtDurationEnd>
                </Repetition>
                <StartBoundary>#{Time.now.strftime("%Y-%m-%dT%H:%M:%S")}</StartBoundary>
                <Enabled>true</Enabled>
              </TimeTrigger>
            </Triggers>
            <Principals>
              <Principal id="Author">
          #{user ? "      <UserId>#{h[user]}</UserId>\n" : ""}      <LogonType>InteractiveToken</LogonType>
                <RunLevel>LeastPrivilege</RunLevel>
              </Principal>
            </Principals>
            <Settings>
              <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
              <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
              <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
              <StartWhenAvailable>true</StartWhenAvailable>
              <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
              <Enabled>true</Enabled>
            </Settings>
            <Actions Context="Author">
              <Exec>
                <Command>#{h[job.argv.first]}</Command>
                <Arguments>#{h[job.argv.drop(1).map { |a| quote(a) }.join(" ")]}</Arguments>
              </Exec>
            </Actions>
          </Task>
        XML
      end

      def install(job)
        FileUtils.mkdir_p(File.dirname(job.log_path))
        Dir.mktmpdir do |dir|
          file = File.join(dir, "task.xml")
          File.binwrite(file, "﻿#{definition(job)}".encode("UTF-16LE"))
          _out, err, ok = Scheduler.run("schtasks", "/Create", "/TN", task(job.name), "/XML", file, "/F")
          raise Error.new(:scheduler, "schtasks /Create failed: #{err.strip}") unless ok
        end
        Scheduler.run("schtasks", "/Run", "/TN", task(job.name))
      end

      def uninstall(name)
        Scheduler.run("schtasks", "/Delete", "/TN", task(name), "/F")
      end

      def status(name)
        out, _err, ok = Scheduler.run("schtasks", "/Query", "/TN", task(name), "/V", "/FO", "LIST")
        return { installed: false } unless ok

        fields = out.lines.map(&:strip).select { |l| l =~ /\A(Status|Last Run Time|Last Result|Next Run Time):/ }
        { installed: true, summary: "Task Scheduler#{", " + fields.join(", ") unless fields.empty?}" }
      end
    end
  end
end
