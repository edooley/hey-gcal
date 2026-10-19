# hey-gcal

**Want your HEY calendar on your Google Calendar?** hey-gcal copies every event
from your [HEY](https://hey.com) calendar onto a Google calendar you choose and
keeps it up to date. When a meeting is moved, renamed, cancelled or declined in
HEY, the Google copy follows within minutes. Nothing flows back the other way.

It also fixes the annoying part: **Google Meet links stay the original link.**
If you copy an invite into Google Calendar by hand, Google often attaches a new
Meet link of its own, and that link doesn't work for a meeting someone else set
up. hey-gcal never asks Google for a Meet link. It puts the original link in the
event's location and on the first line of its description. Google's "Join with
Google Meet" button either shows that same link or isn't there at all.

- **Works on macOS, Linux and Windows.** It runs on your own computer as a
  small background job, every 5 minutes.
- **Plain Ruby, no gems.** There is no server and no third-party service that
  sees your calendar.
- **Reads HEY through the official [`hey` CLI](https://github.com/basecamp/hey-cli).**
  Writes to Google through your own Google sign-in.
- **Never emails the people on your invites.** It only ever touches events it
  created itself.

**Setup takes about 20 minutes, once.** Most of that is creating a Google
"OAuth client" in Google Cloud Console, which is a few minutes of clicking. A
guided `hey-gcal setup` command does everything else.

---

## Quick start

1. [Install Ruby and the `hey` CLI](#1-install-ruby-and-the-hey-cli), and sign
   in with `hey auth login`.
2. [Get hey-gcal](#2-get-hey-gcal).
3. [Create your Google OAuth client](#3-create-your-google-oauth-client) and
   download its JSON file.
4. Run `hey-gcal setup`. It finds the JSON file, asks for your calendar,
   signs you in to Google, shows what it will do, and turns the sync on.

**On Omarchy?** Skip to [On Omarchy](#on-omarchy): it's even shorter, and you
get a bar icon.

The steps are explained in full below. Steps
[4](#4-choose-the-google-calendar) and
[5](#5-failure-emails-with-healthchecksio-recommended) cover what `setup` will
ask you for.

## Contents

0. [On Omarchy](#on-omarchy) (Omarchy users start here)
1. [Install Ruby and the `hey` CLI](#1-install-ruby-and-the-hey-cli)
2. [Get hey-gcal](#2-get-hey-gcal)
3. [Create your Google OAuth client](#3-create-your-google-oauth-client)
4. [Choose the Google calendar](#4-choose-the-google-calendar)
5. [Failure emails with Healthchecks.io (recommended)](#5-failure-emails-with-healthchecksio-recommended)
6. [Run setup](#6-run-setup)

Reference: [Day to day](#day-to-day) · [How it works](#how-it-works) ·
[Where things are kept](#where-things-are-kept) ·
[Configuration](#configuration) · [Commands](#commands) ·
[Troubleshooting](#troubleshooting) ·
[Security and privacy](#security-and-privacy) · [Uninstall](#uninstall) ·
[FAQ](#faq) · [Development](#development)

---

## On Omarchy

[Omarchy](https://omarchy.org) already ships everything hey-gcal needs: Ruby,
git, mise, and the GNOME keyring. hey-gcal fits in the Omarchy way:

- **Bar icon.** A calendar icon in the bar turns into an alert when the sync
  needs you. Click it for status and the steps to fix a problem; right-click to
  sync now. It's one of Omarchy's built-in *custom command modules*, so no
  hey-gcal code runs inside `omarchy-shell`.
- **Notifications** go through `omarchy-notification-send`, Omarchy's own
  notification path. They match your theme, stay quiet under Do Not Disturb
  (they still land in history), and clicking one opens the status in a
  terminal.
- **Your Google sign-in** is kept in the GNOME keyring, and **the sync runs as
  a systemd user timer**. Both are standard Omarchy plumbing.

### Install on Omarchy

**1. Install the HEY CLI the Omarchy way.** Skip this if `hey` already works,
for example because you installed HEY's
[Omarchy bar plugin](https://github.com/basecamp/omarchy-hey-plugin):

```bash
omarchy-mise-install github:basecamp/hey-cli hey
```

**2. Sign in to HEY:**

```bash
hey auth login
```

**3. Get hey-gcal and put it on your PATH.** Omarchy puts `~/.local/bin` on
your PATH already:

```bash
git clone https://github.com/edooley/hey-gcal.git ~/.local/share/hey-gcal && ln -s ~/.local/share/hey-gcal/bin/hey-gcal ~/.local/bin/hey-gcal
```

**4. Create your Google OAuth client.** Follow
[step 3](#3-create-your-google-oauth-client) below. It's done in the browser,
the same on every OS.

**5. Run setup:**

```bash
hey-gcal setup
```

When setup turns the sync on, the icon appears at the start of the bar's
right section. Drag it wherever you like. Your previous
`~/.config/omarchy/shell.json` is kept as `shell.json.hey-gcal.bak`. To skip
the icon, run `hey-gcal install --no-bar`.

### Living with it on Omarchy

- **Status:** click the bar icon, or run `hey-gcal status`.
- **Sync now:** right-click the bar icon.
- **Timer:** `systemctl --user status hey-gcal-default.timer`. Logs are in
  `~/.local/state/hey-gcal/`.
- **Update hey-gcal:**

  ```bash
  git -C ~/.local/share/hey-gcal pull
  ```

- **Remove it:** `hey-gcal uninstall --forget` stops the timer, deletes the
  saved sign-in and takes the icon off the bar. Then delete
  `~/.local/share/hey-gcal` and `~/.local/bin/hey-gcal`.

**Why not an Omarchy plugin?** Omarchy plugins are QML that runs unsandboxed
inside `omarchy-shell`. hey-gcal only needs a status icon, and Omarchy's
built-in custom command modules show one without putting any third-party code
inside your shell. That's the lighter, safer fit.

## 1. Install Ruby and the `hey` CLI

hey-gcal needs **Ruby 3.0 or newer** and the **`hey` CLI, signed in to your HEY
account**. Use the section for your OS.

### macOS

macOS still ships Ruby 2.6, which is too old. Install a current Ruby with
[Homebrew](https://brew.sh):

```bash
brew install ruby
```

Homebrew's Ruby isn't on your PATH by default; `brew info ruby` prints the line
to add to `~/.zshrc`. Any other Ruby manager (mise, rbenv, asdf) works too.

Install the `hey` CLI and sign in:

```bash
curl -fsSL https://hey.com/install-cli | bash
```

```bash
hey auth login
```

### Linux

(On Omarchy, see [On Omarchy](#on-omarchy) instead.)

Install Ruby from your distribution:

| Distribution | Command |
|---|---|
| Debian / Ubuntu | `sudo apt install ruby` |
| Fedora | `sudo dnf install ruby` |
| Arch | `sudo pacman -S ruby` |

Install the `hey` CLI and sign in:

```bash
curl -fsSL https://hey.com/install-cli | bash
```

```bash
hey auth login
```

**Recommended:** install `secret-tool`, so your Google sign-in is kept in your
desktop keyring (GNOME Keyring, KWallet) instead of a private file:

| Distribution | Package |
|---|---|
| Debian / Ubuntu | `sudo apt install libsecret-tools` |
| Fedora | `sudo dnf install libsecret` |
| Arch | `sudo pacman -S libsecret` |

### Windows

Install Ruby with [RubyInstaller](https://rubyinstaller.org/downloads/): pick
the recommended **Ruby+Devkit 3.x (x64)** and accept the defaults. You can also
use winget:

```powershell
winget install RubyInstallerTeam.Ruby.3.3
```

Install the `hey` CLI from PowerShell and sign in:

```powershell
irm https://hey.com/install-cli.ps1 | iex
```

```powershell
hey auth login
```

Open a **new** terminal window afterwards, so `ruby` and `hey` are found.

### Check it worked (all OSes)

```bash
ruby -v
```

```bash
hey event week
```

`ruby -v` should print 3.0 or higher, and `hey event week` should list this
week's events. More install options for `hey` (Homebrew, Scoop, Nix, packages)
are in its [install guide](https://github.com/basecamp/hey-cli/blob/main/docs/install.md).

## 2. Get hey-gcal

Clone it with git, or download the ZIP from GitHub (**Code → Download ZIP**) and
unpack it to the same place.

**macOS / Linux:**

```bash
git clone https://github.com/edooley/hey-gcal.git ~/hey-gcal
```

**Windows (PowerShell):**

```powershell
git clone https://github.com/edooley/hey-gcal.git $HOME\hey-gcal
```

### Make the `hey-gcal` command available

This step is optional but makes life easier. The rest of this guide types
`hey-gcal`. If you skip it, type the full path instead:
`~/hey-gcal/bin/hey-gcal` on macOS/Linux, or `~\hey-gcal\bin\hey-gcal.cmd` on
Windows.

**macOS / Linux:**

```bash
mkdir -p ~/.local/bin && ln -s ~/hey-gcal/bin/hey-gcal ~/.local/bin/hey-gcal
```

If `hey-gcal version` then says "command not found", add `~/.local/bin` to your
PATH and open a new terminal. For zsh, the default on macOS:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

For bash, the default on most Linux, use `~/.bashrc` instead.

**Windows (PowerShell):** add hey-gcal's `bin` folder to your user PATH, then
open a new terminal:

```powershell
$p = [Environment]::GetEnvironmentVariable("Path", "User"); [Environment]::SetEnvironmentVariable("Path", "$p;$HOME\hey-gcal\bin", "User")
```

Check it:

```bash
hey-gcal version
```

## 3. Create your Google OAuth client

Google only lets an app use your calendar through an **OAuth client**.
hey-gcal doesn't ship one. You create your own, which keeps it between you and
Google: no shared app and no middleman. This is the longest step (about 10
minutes), and you only do it once.

Do all of this **signed in as the Google account that should own the synced
events**.

> Google Cloud Console's layout changes now and then. If a button has moved,
> look for the page names used here: *Google Auth Platform*, *Branding*,
> *Audience*, *Data Access*, *Clients*.

### 3a. Create a project

1. Open <https://console.cloud.google.com/projectcreate>.
2. **Project name:** `hey-gcal`. Leave the rest as is and click **Create**.
3. Make sure the new project is selected in the project picker at the top of the
   page. All the steps below happen inside it.

### 3b. Turn on the Google Calendar API

1. Open <https://console.cloud.google.com/apis/library/calendar-json.googleapis.com>.
2. Click **Enable**.

### 3c. Set up the sign-in screen

Open <https://console.cloud.google.com/auth/overview> (**Google Auth
Platform**). If you see **Get started**, click it and fill in the wizard with
the values below. Otherwise use the pages in the left-hand menu.

**Branding**

| Field | What to enter |
|---|---|
| App name | `hey-gcal` |
| User support email | your email |
| Application home page | `https://github.com/edooley/hey-gcal` |
| Application privacy policy link | `https://github.com/edooley/hey-gcal/blob/main/PRIVACY.md` |
| Authorized domains | `github.com`, if it asks |
| Developer contact email | your email |

- **Leave the logo empty.** Uploading one triggers a review by Google.
- **The home page and privacy policy links** are needed to publish (below).
  Google only checks them if you submit the app for verification, which a
  personal tool never needs.

**Audience**

- **User type: External.** "Internal" only exists for Google Workspace
  organizations; External works for any account.

**Data Access**

1. Click **Add or remove scopes**.
2. Tick only `https://www.googleapis.com/auth/calendar.events`. Filtering for
   `calendar.events` finds it fastest.
3. Click **Update**, then **Save**.

**Audience → Publish app**

Click **Publish app**, then **Confirm**. The status should now read **In
production**.

> **Don't skip publishing.** While an app is in *Testing*, Google expires its
> sign-ins after 7 days and the sync quietly stops. A published but unverified
> app is fine for personal use. Google shows a "Google hasn't verified this
> app" screen when you sign in, and that's all. You do **not** need to submit
> the app for verification.

### 3d. Create the client and download its JSON

1. Open **Clients** (<https://console.cloud.google.com/auth/clients>) and click
   **Create client**.
2. **Application type: Desktop app**. **Name:** `hey-gcal`. Click **Create**.
3. In the dialog that appears, click **Download JSON**. Google may only show the
   client secret at this point. If you missed it, open the client, add a new
   secret, and download again.

Leave the file in your Downloads folder. `hey-gcal setup` finds it there,
copies it into hey-gcal's config folder (readable only by you), and offers to
delete the download.

## 4. Choose the Google calendar

We recommend a **separate calendar**, e.g. "Work", rather than your main one.
That way you can show, hide, color or share the synced events on their own. To
create one in Google Calendar, go to **Other calendars → + → Create new
calendar**.

To find a calendar's ID:

1. Open <https://calendar.google.com>.
2. In the left sidebar, hover the calendar, click **⋮**, then **Settings and
   sharing**.
3. Check **Access permissions** and **Share with specific people**. Everyone
   listed will see your meeting details and Meet links (see
   [What it exposes](#what-it-exposes)).
4. Under **Integrate calendar**, copy the **Calendar ID**. It looks like
   `abc123…@group.calendar.google.com`. For your main calendar, it's your Gmail
   address.

`setup` will ask for this ID. The calendar can also be one someone shared with
you, as long as you have **Make changes to events** permission.

## 5. Failure emails with Healthchecks.io (recommended)

The sync runs unattended, so you'll want to hear about it when something
breaks. [Healthchecks.io](https://healthchecks.io) is a free service for exactly
this. It's optional, but without it nothing warns you if the sync stops.

1. Sign up at <https://healthchecks.io> with the email address that should get
   alerts.
2. Click **Add Check** and name it `hey-gcal`.
3. Click **Change Schedule**:
   - **Period:** 5 minutes, or your `--interval`.
   - **Grace Time:** how long the sync may go quiet before you get an email.
     Pick whatever suits you. 1 day suits a laptop that's often closed or
     asleep; a few hours suits a desktop that's always on. Shorter means
     you'll hear sooner, but you may also get an email every time the
     computer is off for longer than that.

   Save.
4. Copy the check's **ping URL**, like `https://hc-ping.com/<uuid>`. `setup` asks
   for it, and for the Grace Time you chose (saved as `stale_after_hours`).
   Then `hey-gcal status` and the Omarchy bar icon warn after the same quiet
   period that triggers the email.

What you'll get:

- **An email as soon as a run fails in a way you need to fix.** It says what
  broke, what that means for your calendar, and the exact steps to fix it (see
  [Troubleshooting](#troubleshooting)).
- **An email if nothing has synced within your Grace Time.** This catches the computer
  being off, the background job being removed, or Ruby being uninstalled.
  Healthchecks notices the silence even when hey-gcal can't run at all.
- **A "back up" email** once it recovers.

Brief network or Google hiccups are retried quietly. They only alert after 3
failed runs in a row.

## 6. Run setup

```bash
hey-gcal setup
```

`setup` walks through everything, one step at a time:

1. Checks that the `hey` CLI is installed and signed in.
2. Creates your config file.
3. Finds the OAuth client JSON in your Downloads (or asks where it is) and copies
   it into place.
4. Asks for the calendar ID, and for an optional title prefix (e.g. `Work: `)
   so synced events are easy to spot.
5. Asks for the Healthchecks ping URL. Press Enter to skip.
6. Signs you in to Google. A browser opens, and Google warns **"Google hasn't
   verified this app"**. It's your own app, so click **Advanced → Go to hey-gcal
   (unsafe)** and allow access to calendar events.
7. Shows exactly what the first sync would add, without changing anything.
8. Asks whether to turn it on. If you say yes, it syncs once and installs the
   background job.

You can re-run `setup` any time: steps that are already done are skipped.
Afterwards, open an event with a Meet link in Google Calendar and check that the
link is the original one.

**Re-run `hey-gcal install` if you move the hey-gcal folder, switch Ruby
versions, or reinstall the `hey` CLI.** The background job remembers the exact
paths that existed when it was installed.

<details>
<summary>Prefer to do it by hand?</summary>

1. `hey-gcal init` writes a config template. Its path is shown in
   [Where things are kept](#where-things-are-kept).
2. Copy your OAuth client JSON next to it as `client_secret.json`.
3. Set `google.calendar_id`, and optionally `healthchecks_url`, in the config.
4. Run `hey-gcal auth`, then `hey-gcal sync --dry-run`, then `hey-gcal sync`,
   then `hey-gcal install`.

</details>

---

## Day to day

```bash
hey-gcal status
```

`status` shows whether the background job is installed, the last run, the last
success, and any problem along with the steps to fix it.

```bash
hey-gcal doctor
```

`doctor` checks every piece of the setup, one by one: Ruby, `hey`, the config,
the Google client and sign-in, the calendar, and the background job.

When a new problem starts, you also get a desktop notification on macOS, on
Omarchy (click it for the fix), and on other Linux desktops that have
`notify-send`.

## How it works

Every run:

1. **Reads HEY** with `hey event week --json`, one week at a time, from 7 days
   ago to 90 days ahead. Repeating events come back as one entry per day.
   Declined invites are left out by default.
2. **Reads Google**, looking only at events hey-gcal created on your chosen
   calendar. Each one carries hidden private properties: a `hey_sync` marker,
   the HEY event's key, and a fingerprint of what was written.
3. **Makes Google match HEY.** It adds new events, rewrites changed ones, and
   deletes ones that are gone from HEY. It leaves everything else untouched, so
   a run with no changes writes nothing.

The link between a HEY event and its Google copy is stored *in* the Google
event, so there's no local database to drift or lose.

What each Google copy contains:

| Field | Value |
|---|---|
| Title, start, end, time zone | From HEY. All-day events stay all-day. |
| Location | The original Meet link, or HEY's location if there isn't one |
| Description | `Join: <Meet link>` first. With `detail: "full"`, then HEY's notes, the organizer, the guest list as text, and a link back to HEY. |
| Guests | **None.** Real guests would let Google email them. |
| Meet button | The original link, or no button. Never a new Meet. |

Edits made on the Google side are overwritten the next time the HEY event
changes. It's a one-way mirror.

### The background job

| OS | Runs as | When |
|---|---|---|
| macOS | launchd agent `~/Library/LaunchAgents/hey-gcal.<name>.plist` | Every 5 min while you're logged in; catches up after sleep |
| Linux | systemd user timer `hey-gcal-<name>.timer`, or a crontab line if there's no systemd user session | Every 5 min while you're logged in (systemd) or while the machine is on (cron) |
| Windows | Task Scheduler task `hey-gcal-<name>`, running `rubyw.exe` so no window flashes | Every 5 min while you're logged in; catches up after sleep |

On Linux with systemd, the timer stops when you log out. To keep it running
while you're logged out, run `loginctl enable-linger $USER`.

## Where things are kept

| | macOS | Linux | Windows |
|---|---|---|---|
| Config + OAuth client | `~/.config/hey-gcal/` | `~/.config/hey-gcal/` (or `$XDG_CONFIG_HOME`) | `%APPDATA%\hey-gcal\` |
| Google sign-in | login Keychain (service `hey-gcal`) | desktop keyring via `secret-tool`, else `~/.config/hey-gcal/<name>.token` (mode 600) | `%APPDATA%\hey-gcal\<name>.token.dpapi`, encrypted with your Windows login |
| Status | `~/.local/state/hey-gcal/` | `~/.local/state/hey-gcal/` (or `$XDG_STATE_HOME`) | `%LOCALAPPDATA%\hey-gcal\state\` |
| Logs | `~/Library/Logs/hey-gcal/` | `~/.local/state/hey-gcal/` | `%LOCALAPPDATA%\hey-gcal\logs\` |

`<name>` is the `name` in your config (`default` unless you change it).

## Configuration

`config.json`:

| Key | Default | Meaning |
|---|---|---|
| `name` | `"default"` | Name of this sync. Used in the background job's name, the saved sign-in, and the log and state files. |
| `google.calendar_id` | (required) | The Google calendar to sync into. |
| `google.client_secret_path` | `"client_secret.json"` | Your OAuth client JSON. A relative path is relative to the config file's folder. |
| `google.token_store` | `"auto"` | Where to keep the Google sign-in: `auto` (best for your OS), `keychain`, `secret-service`, `dpapi`, or `file`. |
| `hey.bin` | `null` | Path to the `hey` CLI. If null, it's found on your PATH. |
| `hey.account` | `null` | Passed to `hey` as `--account` (an id from `hey account list`). |
| `hey.calendars` | `[]` | Only sync these HEY calendars, by name or id (see `hey calendar list`). `[]` means every calendar HEY shows. |
| `sync.past_days` / `sync.future_days` | `7` / `90` | The date range kept in sync. Older events are left as they are. |
| `sync.skip_declined` | `true` | Leave out invites you declined, and remove them if you decline later. |
| `sync.title_prefix` | `""` | Text put in front of every copied title, exactly as written. For example, `"Work: "` turns "Standup" into "Work: Standup". Include the trailing space. Changing it updates existing copies on the next run. |
| `sync.detail` | `"full"` | `"full"`: notes, organizer, guests and a HEY link. `"minimal"`: title, time and Meet link only. |
| `sync.max_deletes` / `sync.max_delete_ratio` | `5` / `0.3` | Safety limits. A run that would delete more than this stops and alerts you instead. |
| `healthchecks_url` | `null` | Your Healthchecks.io ping URL. |
| `stale_after_hours` | `24` | How long without a successful sync before `hey-gcal status` and the Omarchy bar icon flag a problem. Set it to your Healthchecks Grace Time so they agree. Any number of hours works. |

### Syncing to more than one Google calendar

Use one config per target, each with its own `name` and `calendar_id`, and pass
`--config` to every command. For example:

```bash
hey-gcal setup --config ~/.config/hey-gcal/family.json
```

## Commands

| Command | What it does |
|---|---|
| `hey-gcal setup` | Guided setup. Safe to re-run. |
| `hey-gcal status` | Last run and any current problem, with steps to fix it. `--wait` keeps the window open until you press a key. |
| `hey-gcal doctor` | Checks every part of the setup. |
| `hey-gcal sync` | Runs once. `--dry-run` shows the changes without making them. `--allow-deletes` overrides the safety limits for this one run. |
| `hey-gcal auth` | Signs in to Google again. |
| `hey-gcal install` | Starts the background job. `--interval SECONDS` sets how often it runs (default 300). On Omarchy it also adds the bar icon; `--no-bar` skips that. |
| `hey-gcal uninstall` | Stops the background job. `--forget` also deletes the saved Google sign-in. |
| `hey-gcal init` | Just writes a config template. |
| `hey-gcal bar` | Prints the status as Waybar-style JSON. The Omarchy bar icon uses it, and so can any bar that reads this format. |

Every command takes `--config PATH`.

## Troubleshooting

Failure emails, notifications and `hey-gcal status` all name one of these:

| Problem | What to do |
|---|---|
| **HEY CLI is signed out** | Run `hey auth login`, then check `hey auth status`. The next run catches up. |
| **HEY CLI failed or changed** | Check that `hey event week --json` works. If `hey` was moved or reinstalled, re-run `hey-gcal install`. If its output changed shape, hey-gcal needs an update; please open an issue. |
| **Google sign-in needs renewing** | Run `hey-gcal auth`. If it happens every 7 days or so, your OAuth app is still in Testing: publish it (step 3c). |
| **Can't reach the Google calendar** | Check that the calendar still exists, that your account can make changes to its events, and that `google.calendar_id` is right. |
| **Can't read the saved Google sign-in** | Make sure you're logged in to the computer (keyrings unlock at login). Allow access if the system asks. Run `hey-gcal auth` to save a fresh sign-in. |
| **Couldn't set up the background job** | Read the scheduler's error, then run `hey-gcal install` again. |
| **Stopped a large delete** | Check in HEY that the listed events really are gone, then run `hey-gcal sync --allow-deletes` once. If they aren't gone, HEY gave an incomplete answer; wait for the next run. |
| **Some events failed to sync** | Read the error next to each event in the email, then run `hey-gcal sync` again. |
| **Google changed a Meet link** | Join from the link on the first line of the description, and please open an issue. |
| **Network or Google outage** | Usually clears up on its own. Check your connection and <https://www.google.com/appsstatus/dashboard/>. |

If something still isn't right:

- **Nothing happens at all.** Run `hey-gcal doctor`. Also look at the
  `<name>.scheduler.log` file in the logs folder, which catches errors from
  before hey-gcal starts (for example, a Ruby version that was removed).
- **An event is missing.** It must be inside the date range, on a HEY calendar
  that's switched on in HEY, and not declined. `hey-gcal sync --dry-run` shows
  what hey-gcal sees.
- **Windows: no notifications.** That's expected: hey-gcal doesn't show desktop
  notifications on Windows. Use Healthchecks.io for alerts.

## Security and privacy

What hey-gcal can reach, and what protects it:

- **HEY: read-only.** The only `hey` commands it runs are
  `hey event week <date> --json` and `hey auth status --json`. They run
  directly, never through a shell, so event text can't turn into a command.
  hey-gcal never sees your HEY credentials; they stay in the `hey` CLI's own
  storage.
- **Google: one scope.** hey-gcal asks only for `calendar.events`. Google has no
  narrower scope for an existing calendar, so the saved sign-in *could* read
  and edit events on any calendar your account can reach. Treat it like a
  password.
- **Where the sign-in is kept.** It goes in your OS's secret store: the macOS
  Keychain, your Linux desktop keyring, or a file encrypted with your Windows
  login (DPAPI). It only falls back to a private file (mode 600) on Linux
  without a keyring. It's never passed on a command line, so it can't show up
  in a process list.
- **Sign-in flow.** The browser callback listens only on `127.0.0.1`, on a
  random port, with PKCE and a random `state` check. It accepts exactly one
  callback, then closes.
- **Writes are limited to its own events.** It only updates or deletes events
  on your configured calendar that carry hey-gcal's private marker *and* were
  made on that calendar itself: created by your account, or organized by the
  calendar. Invitations from elsewhere don't qualify. It also refuses to add an
  event when a marked copy exists that doesn't pass this check, so the sync can
  never fill your calendar with duplicates.
- **Safety limit on deletes.** Any run that would delete an unusual number of
  events stops. For example, if HEY suddenly returns nothing, it stops instead
  of emptying your calendar.
- **Network.** HTTPS only, with certificate checks on. It connects to:
  - `accounts.google.com` (sign-in, in your browser)
  - `oauth2.googleapis.com`
  - `www.googleapis.com`
  - your Healthchecks host
- **What reports contain.** Healthchecks pings and logs hold counts, event
  titles and error messages, never descriptions, guests, Meet links or tokens.
- **No dependencies.** It uses Ruby's standard library only, so there are no
  third-party packages to trust.

See [PRIVACY.md](PRIVACY.md) for the privacy policy.

### What it exposes

With `detail: "full"`, the Google copies include titles, notes, guest names
and **Meet links**. Anyone who can see that Google calendar can read them and
click into those meetings.

- **Check who the calendar is shared with.** If it matters, use `"minimal"` or
  a calendar only you can see.
- **Check your employer's policies.** Work meeting details will also be stored
  in your Google account.

## Uninstall

```bash
hey-gcal uninstall --forget
```

That stops the background job and deletes the saved Google sign-in. Then:

- Revoke the app at <https://myaccount.google.com/permissions>.
- Delete the config, state and log folders listed in
  [Where things are kept](#where-things-are-kept).
- Delete the hey-gcal folder, and the Google Cloud project if you like.

Events that were already synced stay on the Google calendar until you delete
them.

## FAQ

**Why not just add the invite to Google Calendar myself?**
Google often attaches a new Meet link of its own, which doesn't work for a
meeting someone else created. You'd also have to redo it every time the
meeting moves.

**Will the people on my invites get emails from my Google account?**
No. The copies have no guests, and every write tells Google not to send
updates.

**Does my computer need to be on?**
Yes. It syncs while you're logged in and the computer is awake, and catches up
afterwards. With Healthchecks.io set up, you get an email if it goes longer than
your chosen Grace Time without syncing.

**Can I run it on a server instead?**
It's built for your own computer on purpose. On a server, your HEY login
(which can read your email too, not just your calendar) and your Google sign-in
would live on a machine that's always online. If you do it anyway, use Linux
with `"token_store": "file"` and keep the server locked down.

**Can I sync Google → HEY, or both ways?**
No. It's deliberately one-way: HEY stays the source of truth.

**Is my data sent anywhere else?**
No. It only moves between your computer, HEY and Google, plus counts and titles
to Healthchecks if you set it up.

## Development

Run the tests:

```bash
rake test
```

The tests use fake HEY and Google clients and stub the OS. They never touch the
network or your real calendars, and they cover every platform's code paths on
any OS.

| File | Role |
|---|---|
| `lib/hey_gcal/hey_client.rb` | Reads HEY |
| `lib/hey_gcal/event_mapper.rb` | Turns a HEY event into a Google event |
| `lib/hey_gcal/syncer.rb` | Works out the changes; delete safety checks |
| `lib/hey_gcal/google_client.rb` | Google Calendar API |
| `lib/hey_gcal/oauth.rb` | Google sign-in |
| `lib/hey_gcal/secret_store.rb` | Saving the sign-in (Keychain, keyring, DPAPI, file) |
| `lib/hey_gcal/scheduler.rb` | Background job (launchd, systemd, cron, Task Scheduler) |
| `lib/hey_gcal/platform.rb` | Per-OS folders, browser, notifications |
| `lib/hey_gcal/omarchy.rb` | Omarchy bar icon and notifications |
| `lib/hey_gcal/reporter.rb`, `failure.rb` | Logs, status, alerts |
| `lib/hey_gcal/cli.rb` | Commands, including `setup` and `doctor` |

## License

[MIT](LICENSE)
