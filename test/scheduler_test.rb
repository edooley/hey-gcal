require_relative "test_helper"
begin
  require "rexml/document"
rescue LoadError
  nil
end

class SchedulerTest < Minitest::Test
  S = HeyGcal::Scheduler

  def job(argv: ["/opt/ruby/bin/ruby", "/home/a b/hey-gcal/bin/hey-gcal", "sync", "--config", "/home/a b/.config/hey-gcal/config.json", "--hey-bin", "/usr/bin/hey"], interval: 300)
    S::Job.new(name: "work", argv: argv, interval: interval, log_path: "/tmp/logs/work.scheduler.log")
  end

  def test_job_builds_absolute_argv
    config = Fixtures.config
    j = S.job(config, interval: 600, hey: "/usr/local/bin/hey")
    assert_equal S::BIN, j.argv[1]
    assert_equal ["sync", "--config", config.path, "--hey-bin", "/usr/local/bin/hey"], j.argv[2..]
    assert_equal 10, j.minutes
  end

  def test_launchd_plist
    plist = S::Launchd.new.definition(job)
    assert_includes plist, "<string>hey-gcal.work</string>"
    assert_includes plist, "<string>/home/a b/hey-gcal/bin/hey-gcal</string>"
    assert_includes plist, "<integer>300</integer>"
    assert_includes plist, "<key>RunAtLoad</key>"
  end

  def test_launchd_escapes_xml
    plist = S::Launchd.new.definition(job(argv: ["/r", "/a&b<c>/x"]))
    assert_includes plist, "/a&amp;b&lt;c&gt;/x"
  end

  def test_systemd_units
    systemd = S::Systemd.new
    service = systemd.service(job)
    assert_includes service, %(ExecStart="/opt/ruby/bin/ruby" "/home/a b/hey-gcal/bin/hey-gcal" "sync")
    assert_includes service, "Type=oneshot"
    assert_includes systemd.timer(job), "OnUnitActiveSec=300s"
  end

  def test_systemd_quoting
    line = S::Systemd.new.exec_line(["/x", %(we"ird), "100%", "$HOME", "back\\slash"])
    assert_equal %("/x" "we\\"ird" "100%%" "$$HOME" "back\\\\slash"), line
  end

  def test_cron_line
    line = S::Cron.new.line(job)
    assert line.start_with?("*/5 * * * * HEY_NONINTERACTIVE=1 /opt/ruby/bin/ruby /home/a\\ b/hey-gcal/bin/hey-gcal sync")
    assert line.end_with?("# hey-gcal:work")
    assert S::Cron.new.line(job(interval: 7200)).start_with?("0 */2 * * *")
  end

  def test_task_scheduler_xml
    xml = S::TaskScheduler.new.definition(job(argv: ['C:\Ruby33\bin\rubyw.exe', 'C:\Users\A B\hey-gcal\bin\hey-gcal', "sync", "--config", 'C:\Users\A B\AppData\Roaming\hey-gcal\config.json']))
    assert_includes xml, '<Command>C:\Ruby33\bin\rubyw.exe</Command>'
    assert_includes xml, "<Arguments>&quot;C:\\Users\\A B\\hey-gcal\\bin\\hey-gcal&quot; &quot;sync&quot;"
    assert_includes xml, "<Interval>PT5M</Interval>"
    assert_includes xml, "<LogonType>InteractiveToken</LogonType>"
    assert_includes xml, "<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>"
    REXML::Document.new(xml.sub('encoding="UTF-16"', 'encoding="UTF-8"')) if defined?(REXML)
  end

  def test_windows_quoting
    ts = S::TaskScheduler.new
    assert_equal '"plain"', ts.quote("plain")
    assert_equal '"a \"b\""', ts.quote('a "b"')
    assert_equal '"C:\dir\\\\"', ts.quote('C:\dir\\')
  end
end
