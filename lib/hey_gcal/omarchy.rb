require "fileutils"
require "shellwords"

module HeyGcal
  # Extras for Omarchy (https://omarchy.org), DHH's Arch + Hyprland setup.
  # Everything else on Omarchy is plain Linux: secret-tool + gnome-keyring
  # for the sign-in, a systemd user timer for the job.
  #
  # - A bar icon: a "command" custom module in ~/.config/omarchy/shell.json
  #   that runs `hey-gcal bar` and shows a calendar, or an alert when the
  #   sync needs you. Click for status, right-click to sync now.
  # - Notifications through omarchy-notification-send, Omarchy's sender
  #   contract, so they theme correctly, respect Do Not Disturb, land in
  #   history, and open the status when clicked.
  module Omarchy
    GLYPH_OK = "\u{F00ED}"    # nf-md-calendar
    GLYPH_ALERT = "\u{F0026}" # nf-md-alert
    BAR_INTERVAL = 30

    module_function

    def present?
      Platform.linux? && !Platform.which("omarchy-notification-send").nil? && Dir.exist?(omarchy_path)
    end

    def omarchy_path
      Platform.env_dir("OMARCHY_PATH", "~/.local/share/omarchy")
    end

    def shell_config_path
      File.expand_path("~/.config/omarchy/shell.json")
    end

    def module_id(config)
      config.name == "default" ? "hey-gcal" : "hey-gcal-#{config.name}"
    end

    # argv for running hey-gcal itself with this config.
    def self_argv(config, *args)
      [Platform.stable_ruby, Scheduler::BIN, *args, "--config", config.path]
    end

    def bar_entry(config)
      cmd = ->(*args) { Shellwords.join(self_argv(config, *args)) }
      {
        "id" => module_id(config),
        "type" => "command",
        "exec" => cmd.call("bar"),
        "interval" => BAR_INTERVAL,
        "tooltip" => "hey-gcal",
        "onClick" => Shellwords.join(["omarchy-launch-tui", "--app-id=org.omarchy.hey-gcal", *self_argv(config, "status", "--wait")]),
        "onRightClick" => cmd.call("sync")
      }
    end

    # Waybar-style JSON for the bar module, from the status file alone (no
    # network, so it is cheap to run every 30 seconds).
    def bar_json(state, config, now: Time.now)
      last_success = state["last_success_at"] && Time.iso8601(state["last_success_at"])
      if state["failure"]
        text = GLYPH_ALERT
        tooltip = "hey-gcal: #{state["failure"]["title"]}\nClick for what to do."
        klass = "active"
      elsif last_success.nil?
        text = GLYPH_OK
        tooltip = "hey-gcal: not synced yet\nClick for status, right-click to sync now."
        klass = ""
      elsif now - last_success > config.stale_after_seconds
        text = GLYPH_ALERT
        tooltip = "hey-gcal: no sync for #{ago(now - last_success)}\nClick for status."
        klass = "active"
      else
        text = GLYPH_OK
        tooltip = "hey-gcal: synced #{ago(now - last_success)} ago\n#{state["last_summary"]}\nRight-click to sync now."
        klass = ""
      end
      JSON.generate("text" => text, "tooltip" => tooltip, "class" => klass)
    end

    def ago(seconds)
      seconds = seconds.to_i
      return "#{seconds}s" if seconds < 60
      return "#{seconds / 60} min" if seconds < 3600
      return "#{seconds / 3600} h" if seconds < 86_400

      "#{seconds / 86_400} days"
    end

    # Puts the icon at the start of the right section, or updates it in
    # place. Starts from Omarchy's defaults when you have no shell.json yet,
    # exactly as Omarchy's own `omarchy bar` does, so nothing else moves.
    def add_bar_module(config)
      edit_shell_config do |data|
        entry = bar_entry(config)
        sections = data["bar"]["layout"]
        existing = sections.values.grep(Array).find { |list| list.any? { |e| e.is_a?(Hash) && e["id"] == entry["id"] } }
        if existing
          existing.map! { |e| e.is_a?(Hash) && e["id"] == entry["id"] ? e.merge(entry) : e }
        else
          sections["right"].unshift(entry)
        end
      end
    end

    def remove_bar_module(config)
      return unless File.exist?(shell_config_path)

      edit_shell_config do |data|
        data["bar"]["layout"].each_value do |list|
          list.reject! { |e| e.is_a?(Hash) && e["id"] == module_id(config) } if list.is_a?(Array)
        end
      end
    end

    def bar_module?(config)
      data = JSON.parse(File.read(shell_config_path))
      Array(data.dig("bar", "layout")&.values).flatten.any? { |e| e.is_a?(Hash) && e["id"] == module_id(config) }
    rescue Errno::ENOENT, JSON::ParserError
      false
    end

    def edit_shell_config
      source = File.size?(shell_config_path) ? shell_config_path : File.join(omarchy_path, "config", "omarchy", "shell.json")
      data = File.exist?(source) ? JSON.parse(File.read(source)) : {}
      data = {} unless data.is_a?(Hash)
      data["version"] = 1
      data["bar"] = {} unless data["bar"].is_a?(Hash)
      data["bar"]["layout"] = {} unless data["bar"]["layout"].is_a?(Hash)
      %w[left centerBegin center centerEnd right].each do |section|
        data["bar"]["layout"][section] = [] unless data["bar"]["layout"][section].is_a?(Array)
      end
      yield data

      FileUtils.mkdir_p(File.dirname(shell_config_path))
      FileUtils.cp(shell_config_path, "#{shell_config_path}.hey-gcal.bak") if File.size?(shell_config_path)
      tmp = "#{shell_config_path}.hey-gcal.tmp"
      File.write(tmp, JSON.pretty_generate(data) + "\n")
      File.rename(tmp, shell_config_path)
      system("omarchy-shell", "shell", "reloadConfig", out: File::NULL, err: File::NULL)
    rescue JSON::ParserError => e
      raise Error.new(:scheduler, "Could not read #{source}: #{e.message}")
    end

    def notify(title, message, on_click: nil)
      argv = ["omarchy-notification-send", "--app-name", "hey-gcal", "-g", GLYPH_ALERT, "-u", "normal", title, message]
      argv += ["--exec", "omarchy-launch-tui", "--app-id=org.omarchy.hey-gcal", *on_click] if on_click
      system(*argv, out: File::NULL, err: File::NULL)
    end
  end
end
