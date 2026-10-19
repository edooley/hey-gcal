# hey-gcal privacy policy

hey-gcal is a command-line tool that runs entirely on your own computer. Each
person who uses it creates their own Google OAuth client, so the person
running it is both the app's operator and its only user.

- **What it accesses:** your HEY calendar, read through the `hey` CLI on your
  computer, and the events on the one Google calendar you configure, through
  the Google Calendar API (`calendar.events` scope).
- **What it does with that data:** it copies HEY events onto your Google
  calendar and keeps them up to date. That is all.
- **Where data goes:** only between your computer, HEY and Google. If you set
  up Healthchecks.io, run status pings also go there; they contain counts,
  event titles and error messages only. The author receives nothing, and there
  is no server, analytics or tracking.
- **What it stores:** your Google refresh token in your operating system's
  secret store (macOS Keychain, Linux keyring, or a file encrypted with your
  Windows login), plus a config file, a status file and a log in your user
  folders. Nothing is stored anywhere else.
- **How to remove it:** run `hey-gcal uninstall --forget` and revoke access at
  <https://myaccount.google.com/permissions>.

hey-gcal's use of information received from Google APIs adheres to the
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
including the Limited Use requirements.
