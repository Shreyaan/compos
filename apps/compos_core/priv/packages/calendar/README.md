# Calendar

A calendar for compos. Elixir owns the model, the store and the sync. Scheme owns the views, the commands and the tools. No external program owns a calendar.

This file is the package source. Each heading that carries a tangle header writes its block to the named file.

## Why not one MCP server per provider

An MCP server per provider is a tool zoo. Two accounts on two providers give four servers and four vocabularies, and no one of them holds a merged view. An MCP server is also a chat door only. It cannot draw a week, it cannot hold an edit made offline, and it cannot merge two calendars.

The calendar gets one tool surface through define-tool!. The compos MCP server then serves that surface to an outside agent. One vocabulary, every provider behind it.

## Why not a wrapper over khal or vdirsyncer

Such a program owns the event model and the store. We would parse its output, fight its schema and inherit its recurrence faults. The store is the part we must own, because the store is where a lost edit happens.

## Where gog fits

gog is a Google command line tool. It already holds multi-account OAuth in a keyring, and it answers JSON. It is not a calendar wrapper: it owns no model and no store, and it answers one request.

The Apple surface below reads Google already, so gog is no longer the early phase. It stays as the direct path for a host that is not this Mac, and for anything CalDAV cannot reach.

## Layers

    Scheme    calendar.scm         verbs, tools, the sources list
              calendar-view.scm    week grid, day view, event card
              agenda.scm           existing; gains calendar events

    Elixir    Calendar             facade and supervisor
              Calendar.Sync        one worker per source; tokens and backoff
              Calendar.Mirror      rules that copy events between calendars
              Calendar.Store       SQLite index; the ICS text is the truth
              Calendar.Provider    behaviour
              Calendar.ICS         RFC 5545 read and write
              Calendar.RRule       recurrence expansion

    Providers Apple    the macOS Calendar store, read-only; every account
                       that CalendarAgent already syncs
              CalDAV   iCloud, Fastmail, Nextcloud; the write path
              Google   REST v3 through gog, later a native flow
              ICS      a read-only subscription URL
              Local    a calendar compos owns; no remote
              Morg     agenda.scm dated headings, read-only

Every provider answers the same records. A view never knows which provider a record came from.

## The event model

One struct, Compos.Core.Calendar.Event:

    uid            the RFC 5545 UID
    source_id      which source holds it
    recurrence_id  set on an override of one instance, else nil
    summary        the title
    description    the body
    location
    starts_at      a naive datetime with a tzid, or a date when all day
    ends_at        exclusive, as RFC 5545 says
    all_day?
    rrule          the rule text, not expanded
    exdates        excluded starts
    rdates         extra starts
    status         confirmed, tentative or cancelled
    transparency   busy or free
    organizer      an address
    attendees      address, role, partstat
    sequence       the RFC 5545 revision counter
    etag           the remote validator
    href           the CalDAV path; in CalDAV this is the identity
    updated_at
    ics            the raw component, kept whole

The raw component is kept. Every property we do not model survives a round trip. A round trip that loses a property is a fault.

## The store

SQLite through exqlite, at ~/.compos/calendar.db.

    sources      id, kind, account, name, colour, config_json,
                 sync_token, ctag, last_sync_at, status, error
    events       source_id, uid, recurrence_id, ics, summary, etag,
                 href, deleted
    occurrences  source_id, uid, recurrence_id, starts_utc, ends_utc
    links        local_uid, remote_source_id, remote_uid, rule, hash
    outbox       id, source_id, uid, op, ics, tries, last_error
    conflicts    source_id, uid, local_ics, remote_ics, seen_at

occurrences holds the expanded recurrences for a rolling window, about one year back and two years forward. A view asks one indexed range query. It never expands a rule while it draws. A write to events expands only that event again.

outbox means an edit made offline is not lost. conflicts means a clash is shown, and never resolved in silence.

## Sync

Pull, per provider:

- Google answers an incremental list for a syncToken. A 410 answer means the token expired, and the source must do a full resync. This case happens, so handle it.
- CalDAV uses sync-collection with a sync-token (RFC 6578). Where a server does not support it, fall back to the collection ctag, then a PROPFIND of the hrefs and their ETags, then a multiget of the changed hrefs.
- An ICS URL uses a conditional GET with ETag or Last-Modified. On a change, parse the whole file and compare by UID.

Push: the outbox drains in order. Each write carries If-Match with the stored ETag. A 412 or a 409 answer means the remote changed first. The write then goes to conflicts and the user sees a card. A user edit is never dropped.

Conflict rule: a field the user did not touch takes the remote value. A field that both sides changed makes a conflict row.

A source syncs on a timer, on a manual refresh, and when its buffer wakes. Sync runs off the Session lane through task-run!. Backoff is exponential on an error, and it resets on a success.

## Mirroring

Mirroring is not provider sync. It is a rule between two local sources.

    (calendar-mirror-add! 'work 'personal 'busy)

A rule states a source, a target and a mode. full copies the details. busy copies a block with no title. tagged copies only the events that carry a tag.

links holds the identity map, so a second run updates the copy and does not add a second one. A mirrored event carries X-COMPOS-MIRROR-OF, and a mirrored event is never mirrored again. Two rules in opposite directions cannot loop.

## Two dependency decisions

Time zones. Elixir ships a UTC-only time zone database. A DTSTART with a TZID cannot be resolved without a real one. Add tz, which is small and compiles the IANA data, and set config :elixir, :time_zone_database. This is not optional. Every recurrence across a daylight saving change is wrong without it.

Recurrence. No suitable library is in the tree, and cocktail does not model RFC 5545 directly. Write Calendar.RRule. It is pure, it is about 400 lines, and it is table tested against the RFC 5545 examples. Cover FREQ daily, weekly, monthly and yearly, then INTERVAL, BYDAY, BYMONTHDAY, BYMONTH, BYSETPOS, COUNT, UNTIL and WKST, then EXDATE, RDATE and the RECURRENCE-ID overrides. The overrides are the part that real calendars use, and the part that libraries get wrong.

## The Apple surface

macOS keeps every calendar it syncs in one SQLite file:

    ~/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb

This machine was probed on 2026-09-08. The file holds nine stores: iCloud, Google, Subscribed Calendars, Todoist, Reminders, a holidays subscription and three local ones. The Google calendar svs@svsrecruiting.com holds 518 items and was written the day before the probe. A read gives the summary, the start and end, the IANA time zone, the all day flag and the attendees.

This is the cheapest correct read path on a Mac. CalendarAgent already does the OAuth, the tokens, the incremental sync and the retries. For a read we need no provider sync at all. We open the file and select.

The old per-calendar directory of .ics files is gone. ~/Library/Calendars holds only sync scratch on this release.

### What the probe settled

- Dates are CFAbsoluteTime, which counts seconds from 2001-01-01 UTC. Add 978307200 to reach the Unix epoch.
- start_tz holds an IANA name, or _float for a floating time. An all day event is _float with all_day set.
- OccurrenceCache looks useful and is not. It is a bounded cache of the range the user has looked at. The probe found 2553 rows that stop at 2026-01, while the base tables run to 2031. Read CalendarItem, Recurrence and ExceptionDate, and expand the rules ourselves. Calendar.RRule is still needed.
- A comparison must cast. start_date is a real and strftime answers text, and SQLite never matches a number against text. A query that forgets the cast answers zero rows and looks like an empty calendar.

### Rules for this provider

- Open with immutable=1, or read-only. Never write. Calendar.app owns the file and keeps a live WAL beside it.
- The daemon needs Full Disk Access to read it.
- The schema carries no promise. Probe for the columns we use at connect time, and fail loudly with a clear message when a macOS release moves them. Never fail into an empty calendar in silence.
- It is one machine only. A Linux host has none of this, which is why the CalDAV provider still gets built.

### What it does not give

Writes. An event written into that file would be overwritten, or would corrupt the store. A write goes to CalDAV for the account that owns the event, or through an EventKit helper. Read and write are allowed to use different paths for the same calendar, because the identity is the UID.

## The Scheme surface :tangle calendar.scm

The primitives live in session.ex. The package holds the settings, the verbs, the tools and the views. Elixir never draws, and Scheme never opens a socket.

```scheme
;; Calendar: settings and the read verbs.
;; Elixir owns the model, the store and the sync. This file owns policy.

(domain! 'calendar)
(effects! '(read))

(defcustom 'calendar-store-path "~/.compos/calendar.db"
  "Where the merged calendar store lives.")

(defcustom 'calendar-apple-db
  "~/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb"
  "The macOS calendar store. Read-only, and read only on a Mac.")

(defcustom 'calendar-sync-interval 300
  "Seconds between two syncs of a source that is not asked for.")

(defcustom 'calendar-window-back 365
  "Days before today that the store keeps expanded.")

(defcustom 'calendar-window-forward 730
  "Days after today that the store keeps expanded.")

(defcustom 'calendar-week-start 1
  "The first column of the week grid. 0 is Sunday and 1 is Monday.")
```

The verbs, once the store answers:

    (calendar-sources)                    every source and its state
    (calendar-source-add! KIND CONFIG)    register a source
    (calendar-source-remove! ID)
    (calendar-sync! [ID])                 refresh one source, or all
    (calendar-events FROM TO [SOURCES])   the occurrences in a window
    (calendar-event-put! ID EVENT)        create or update; queues a push
    (calendar-event-delete! ID UID)
    (calendar-conflicts)
    (calendar-mirror-add! FROM TO MODE)

define-tool! wraps the same verbs for chat. The compos MCP server then serves that surface outward. This is the answer to a calendar MCP: one surface, every provider behind it.

## Views

- *Calendars* is a list mode over the sources. Colour, account, last sync, error and event count. g refreshes, s syncs, RET opens the calendar.
- *Calendar* is the week grid, in render-mode blocks, from the ui/* components that agenda.scm and diff-mode already use. Clicks register through on-block-click! in components.scm. Never call the block primitive.
- The event card is an overlay on the grid, and it edits in place.
- *Agenda* gains calendar events beside its morg entries. One list, two origins, one sort.

## Phases

The Apple probe moved the order. A merged read now comes before any network work at all.

P1. Model and store. ICS, RRule, Store, expansion, and the Local provider. No network. Tests only. This phase decides whether the rest is sound.

P2. The Apple provider. Every calendar this Mac holds, read-only, in the merged store. No OAuth, no tokens, no sync engine. This is the phase that makes the calendar useful.

P3. Views. The week grid, the day view, the event card and the agenda merge. Read-only is enough to earn its place.

P4. CalDAV, read and write. iCloud and Fastmail with app passwords. This adds the write path and the first host that is not this Mac.

P5. Google direct, through gog and then natively. Only needed where CalDAV does not reach, or where a non-Mac host must read Google.

P6. Mirroring. Rules, links and the loop guard.

P7. Freebusy and invitation replies.

## Landmines

- Elixir ships a UTC-only time zone database. See the dependency decisions.
- OccurrenceCache is a bounded cache. Do not read it.
- A SQLite comparison of a number against text never matches, and answers an empty calendar rather than an error.
- A Google all day event uses date, not dateTime, and its end is exclusive. A one day event ends the next morning.
- A Google syncToken expires. A 410 answer must force a full resync.
- In CalDAV the href is the identity, not the UID. iCloud invents hrefs.
- RECURRENCE-ID and EXDATE must survive a round trip. Lose one and a cancelled meeting comes back.
- Never call task-run! at load time.
- Store work runs off the Session lane. A synchronous SQLite call inside a command freezes the editor. Open the handle once, not once per query.
- Never test against the live daemon at ~/.compos/sock.
- define-list-mode! caches its options. A new option key needs the definition to run again, and a hot reload alone does not reach it.

## Open decisions

1. Is the Apple surface enough for the first release? It reads every account already. If so, P4 and P5 wait until a write is wanted.
2. Two-way write, or read plus a local calendar that compos owns?
3. Mirroring: full details, or busy blocks only?
4. Does this replace the gog cron that writes ~/docs/Work/schedule.org, or run beside it?
5. Store path: ~/.compos/calendar.db is assumed.
