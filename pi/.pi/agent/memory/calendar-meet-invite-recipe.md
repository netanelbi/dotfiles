---
name: calendar-meet-invite-recipe
summary: Google Meet invite via gws: needs conferenceDataVersion=1 + sendUpdates=all; Hagai Karchi is hagai@c-crop.com
pinned: true
created: 2026-09-27
modified: 2026-09-27
---
Calendar is `netanel@c-crop.com` (= `primary`). Verified 2026-09-27 (event 66trs18ghrvpgrb431opvm41hs).

One command creates the event, mints the Meet link, and emails the invite:

```bash
gws calendar events insert --params '{"calendarId":"primary","conferenceDataVersion":1,"sendUpdates":"all"}' --json '{
  "summary":"Meeting with Hagai",
  "start":{"dateTime":"2026-09-27T09:00:00+03:00","timeZone":"Asia/Jerusalem"},
  "end":{"dateTime":"2026-09-27T10:00:00+03:00","timeZone":"Asia/Jerusalem"},
  "attendees":[{"email":"hagai@c-crop.com"}],
  "conferenceData":{"createRequest":{"requestId":"<unique>","conferenceSolutionKey":{"type":"hangoutsMeet"}}},
  "reminders":{"useDefault":true}
}'
```

Read back: `gws calendar events get --params '{"calendarId":"primary","eventId":"<id>"}'` — check `hangoutLink` and each attendee's `responseStatus`.

Gotchas:
- `conferenceDataVersion:1` is required, else no Meet link.
- `sendUpdates:"all"` is required, else same-domain c-crop attendees are never emailed (same rule as the work agent's `feedback_calendar_notify_all`).
- No `notificationLevel` field exists in Calendar API v3 events — don't send one.
- `gws` prints `Using keyring backend: keyring` on **stderr**, so use `2>/dev/null` and parse directly. Do NOT also `sed '1d'` (eats the `{`), and don't `2>&1 | json.tool`.
- Free/busy: `gws calendar events list --params '{"calendarId":"primary","timeMin":...,"timeMax":...,"singleEvents":true,"orderBy":"startTime"}'`.
- The people directory API is empty: `gws people people searchContacts --params '{"query":"x","readMask":"names,emailAddresses"}'` returns `{}`. Resolve an address from Gmail instead — list with `q:<name>`, then read the message's `From`/`To` headers.
- `recall --full` on long transcripts runs >30s; background it or skip.
- Auto-recording is not set by this command (work memory `meet-auto-recording-via-gws`) — ask whether he wants it.
