require "rbconfig"

module HeyGcal
  # Where things live and how to talk to the desktop on macOS, Linux and
  # Windows. Everything OS-specific outside the secret store and scheduler
  # goes through here.
  module Platform
    module_function

    def os
      case RbConfig::CONFIG["host_os"]
      when /darwin/ then :macos
      when /mswin|mingw|cygwin/ then :windows
      else :linux
      end
    end

    def macos? = os == :macos
    def windows? = os == :windows
    def linux? = os == :linux

    # macOS / Linux: ~/.config/hey-gcal (or $XDG_CONFIG_HOME/hey-gcal)
    # Windows:       %APPDATA%\hey-gcal
    def config_dir
      if windows?
        File.join(env_dir("APPDATA", "~/AppData/Roaming"), "hey-gcal")
      else
        File.join(env_dir("XDG_CONFIG_HOME", "~/.config"), "hey-gcal")
      end
    end

    # macOS / Linux: ~/.local/state/hey-gcal (or $XDG_STATE_HOME/hey-gcal)
    # Windows:       %LOCALAPPDATA%\hey-gcal\state
    def state_dir
      if windows?
        File.join(env_dir("LOCALAPPDATA", "~/AppData/Local"), "hey-gcal", "state")
      else
        File.join(env_dir("XDG_STATE_HOME", "~/.local/state"), "hey-gcal")
      end
    end

    # macOS: ~/Library/Logs/hey-gcal (shows up in Console.app)
    # Linux: the state dir; Windows: %LOCALAPPDATA%\hey-gcal\logs
    def log_dir
      case os
      when :macos then File.expand_path("~/Library/Logs/hey-gcal")
      when :windows then File.join(env_dir("LOCALAPPDATA", "~/AppData/Local"), "hey-gcal", "logs")
      else state_dir
      end
    end

    def env_dir(name, fallback)
      value = ENV[name].to_s
      File.expand_path(value.empty? ? fallback : value)
    end

    # Absolute path of an executable on PATH (honoring PATHEXT on Windows).
    def which(command)
      exts = windows? ? ENV.fetch("PATHEXT", ".EXE;.BAT;.CMD").split(";").map(&:downcase) + [""] : [""]
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        exts.each do |ext|
          path = File.join(dir, "#{command}#{ext}")
          return File.expand_path(path) if File.file?(path) && File.executable?(path)
        end
      end
      nil
    end

    # The Ruby the background job should run. On Windows, rubyw.exe runs
    # without flashing a console window every few minutes.
    def background_ruby
      ruby = stable_ruby
      return ruby unless windows?

      rubyw = File.join(File.dirname(ruby), "rubyw.exe")
      File.exist?(rubyw) ? rubyw : ruby
    end

    # A Ruby installed by mise lives under a versioned folder that disappears
    # when you upgrade. Prefer mise's `ruby` shim, which follows your global
    # version, as long as it works from a neutral folder.
    def stable_ruby(ruby = RbConfig.ruby)
      return ruby unless ruby.include?("/mise/installs/ruby/")

      shim = File.join(env_dir("MISE_DATA_DIR", "~/.local/share/mise"), "shims", "ruby")
      return ruby unless File.executable?(shim)

      out = IO.popen([shim, "-e", "print RUBY_VERSION"], chdir: Dir.home, err: File::NULL, &:read)
      $?.success? && Gem::Version.new(out) >= Gem::Version.new("3.0") ? shim : ruby
    rescue SystemCallError, ArgumentError
      ruby
    end

    # Opens a URL in the default browser, without going through a shell (the
    # URL is full of & and ? characters).
    def open_url(url)
      case os
      when :macos then system("open", url)
      when :windows then system("rundll32", "url.dll,FileProtocolHandler", url)
      else which("xdg-open") && system("xdg-open", url, out: File::NULL, err: File::NULL)
      end
    end

    # Best-effort desktop notification; silently does nothing where there is
    # no notifier. Healthchecks.io is the reliable alert channel. on_click
    # (argv) is only honored on Omarchy, whose notifications can run a command.
    def notify(title, message, on_click: nil)
      return Omarchy.notify(title, message, on_click: on_click) if Omarchy.present?

      case os
      when :macos
        script = ["on run argv", "display notification (item 2 of argv) with title (item 1 of argv)", "end run"]
        system("/usr/bin/osascript", *script.flat_map { |line| ["-e", line] }, title, message, out: File::NULL, err: File::NULL)
      when :linux
        system("notify-send", "--app-name=hey-gcal", title, message, out: File::NULL, err: File::NULL) if which("notify-send")
      end
    rescue SystemCallError
      nil
    end
  end
end
