# Calendar

One calendar surface over every account the operating system already knows about. The store is a text file. Scheme owns the verbs, the parse and the views. There is no Elixir module, no compiled binary, no OAuth client, no token, and on macOS no CalDAV.

This is not a Google Calendar MCP. One MCP server per provider is a tool zoo: two accounts on two providers gives four servers, four vocabularies and no merged view. An MCP server is also a chat door only, so it cannot draw a week, hold an offline edit or merge two calendars. Instead we build one verb surface, wrap it once with define-tool!, and the compos MCP server serves it outward for free.

## What the probes settled

Every row below was measured on this machine on 2026-09-08, not assumed.

| question | answer | evidence |
| --- | --- | --- |
| Does macOS ship a calendar CLI? | No, cal is a month grid | Calendar.app is scriptable but ships no command |
| Can we reach EventKit without a compiler? | Yes, osascript -l JavaScript and the ObjC bridge | probe.js returns real calendar titles |
| Does the compos daemon get calendar access? | No, and it never can | launchctl managername is Background, and TCC cannot prompt a Background process |
| Does a LaunchAgent get access? | Yes | same script, same second: Aqua returned 10 calendars, Background returned 0 |
| Does the grant follow the binary into the daemon? | No | TCC records kTCCServiceCalendar for /bin/zsh as allowed, and the daemon still reads 0 |
| Can we write? | Yes, to a real Google account | created, read back and deleted an event in the Google account |
| Do we need an RRule engine? | No | EventKit returns expanded occurrences, not rules |
| Does Google CalDAV take an app password? | No | PROPFIND returns 401 with no WWW-Authenticate header at all, Bearer only |
| Does iCloud CalDAV take an app password? | Yes | 401 with WWW-Authenticate: Basic realm MMCalDav |

The consequence of rows three to six is the whole design: macOS already holds the accounts, the OAuth, the token refresh and the incremental sync for all nine of your stores, and it will hand them over in both directions, but only to a process in the Aqua session.

## The shape

| piece | where | what it does |
| --- | --- | --- |
| the agent | a LaunchAgent, Aqua session | the only thing that touches EventKit; reads calendars, drains the outbox |
| the payload | agent/*.js, run by osascript -l JavaScript | EventKit calls, no compiler and no binary |
| the spool | ~/.compos/calendar/ | request and result files; the door between the two sessions |
| the store | one text file | the truth compos reads and renders; survives with no agent running |
| the parse | Scheme, tree-sitter markdown | (ts-langs) already loads markdown and markdown-inline |
| the views | morg-agenda-mode, plus a week grid | day cards, n and p, TAB fold, RET open, [ and ] by week |

Elixir appears nowhere. The editor already has shell exec and an async lane, so nothing in this list needs a new module, a supervisor or a database.

## Why the agent exists

The compos daemon is started by run_erl -daemon, so its parent is pid 1 and launchctl managername says Background. TCC never prompts a Background process, and a denied EventKit call does not raise. It returns an empty array. That failure mode looks exactly like an empty calendar, which is why it cost an hour before it was measured.

A LaunchAgent with LimitLoadToSessionType set to Aqua runs in the logged-in GUI session and can be prompted. The proof was already in ~/Library/LaunchAgents: gnu.emacs.daemon.plist, with a matching TCC row for org.gnu.Emacs.

So the daemon never calls EventKit. It writes a file and reads a file. That also gives the offline behaviour for free: a write made with the agent unloaded sits in the spool until the agent runs.

## Reading

The agent lists occurrences over a window and writes JSON to the spool. Scheme reads that JSON and rewrites the section of the text file it owns. The file is the store, in the manner of org-gcal-sync: one heading per day, one entry per event, human editable, diffable, and readable with no daemon at all.

EventKit expands recurrence for us. enumerateEventsMatchingPredicate returns occurrences, so EXDATE, RDATE and RECURRENCE-ID overrides are already resolved. That deletes the single largest piece of the original plan, roughly 400 lines of RFC 5545 that libraries routinely get wrong.

The direct SQLite read of Calendar.sqlitedb still works, needs no grant at all, and stays as the fallback for a machine where the agent is not installed. It is a fallback and not the main path for one reason: OccurrenceCache is a bounded cache of the range Calendar.app has been asked to draw, not a full expansion. It held 2553 rows ending 2026-01 while the base tables ran to 2031. Reading it as an expansion silently loses events.

## Writing

A write is a file, not a call.

| step | who | what |
| --- | --- | --- |
| 1 | daemon | writes ~/.compos/calendar/outbox/ID.json |
| 2 | agent | picks it up and runs the EventKit call |
| 3 | agent | writes ID.result, removes the request |
| 4 | daemon | reads the result, updates the text file |

One door writes to every provider, because Calendar.app owns the accounts. An event created in the Google calendar goes out through CalendarAgent's OAuth. There is no per-provider auth, ever. That is the same argument that makes the read path free, applied to writes.

A failed request keeps its result file with the error, so a write is never lost in silence.

## The event record

    uid            the RFC 5545 UID, and the identity across every path
    event_id       the EventKit identifier, valid on this Mac only
    source         the account, for example Google or iCloud
    calendar       the calendar title
    summary        the title
    description    the body
    location
    starts_at      with an IANA time zone, or a date when all day
    ends_at        exclusive, as RFC 5545 says
    all_day?
    status         confirmed, tentative or cancelled
    transparency   busy or free
    organizer      an address
    attendees      address, role, partstat
    href, etag     CalDAV only; the Linux path fills these

uid is the identity, not event_id. That matters because the read path and the write path may differ on the same calendar, and because a Linux host reaching the same account over CalDAV must land on the same record.

## The Scheme surface :tangle calendar.scm

```scheme
;; Calendar: settings and verbs. The agent touches EventKit; this file owns policy.

(domain! 'calendar)
(effects! '(read))

(defcustom 'calendar-file "~/docs/calendar.md"
  "The text store. This file is the truth compos reads and renders.")

(defcustom 'calendar-spool "~/.compos/calendar"
  "Where the daemon and the Aqua agent leave files for each other.")

(defcustom 'calendar-agent-label "io.svs.compos-calendar"
  "The LaunchAgent label. Loaded into gui/UID, never into the daemon.")

(defcustom 'calendar-apple-db
  "~/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb"
  "Fallback read when no agent is installed. Recurrence is not expanded here.")

(defcustom 'calendar-window-back 365
  "Days before today that the text file keeps.")

(defcustom 'calendar-window-forward 730
  "Days after today that the text file keeps.")

(defcustom 'calendar-week-start 1
  "The first column of the week grid. 0 is Sunday and 1 is Monday.")
```

The verbs:

    (calendar-calendars)                  every calendar the OS knows, and its account
    (calendar-sync! [FROM TO])            refresh the window into the text file
    (calendar-events FROM TO [CALS])      the occurrences in a window
    (calendar-event-put! EVENT)           create or update; queues a request
    (calendar-event-delete! UID)
    (calendar-agent-install!)             write the plist and bootstrap the GUI domain
    (calendar-agent-uninstall!)           bootout and remove
    (calendar-agent-status)               loaded, session, last drain, pending count

define-tool! wraps the same verbs for chat, and the compos MCP server then serves them outward. That is the real answer to a calendar MCP: one surface, every account behind it.

## Payload choice

The payload is what the agent runs. It is a cheap and reversible choice, because everything sits behind the spool.

| payload | build | risk |
| --- | --- | --- |
| JXA through osascript | none | the async grant callback does not fire, see landmines |
| sichengchen/tap/apple-calendar-cli | Swift source build, no bottle, needs Xcode | third-party binary, 6 stars, last push 2026-02 |
| @joargp/accli on npm | none, npx | unknown author, reads your calendar |

JXA is in use and works. apple-calendar-cli covers list, get, create, update, delete, recurrence, alerts and --json, so it is the drop-in if JXA turns awkward, at the cost of compiling Swift once through brew.

## Linux

Linux has no OS calendar. Evolution Data Server over D-Bus is GNOME-only and worse than what it replaces. What Linux users actually run is vdirsyncer writing a vdir, a directory of .ics files.

So Linux gets a separate importer into the same text file: CalDAV directly, or an existing vdir. The text store absorbs the difference, and no view knows which host produced a row. iCloud, Fastmail and Nextcloud take an app password. Google does not, and there CalDAV is the worse of the two Google doors, since the REST API gives sync tokens and JSON instead of XML and sync-collection.

## Phases

| phase | what | state |
| --- | --- | --- |
| P1 | the agent: plist, drain script, JXA payloads, install and uninstall verbs | probes done and verified |
| P2 | read into the text file, tree-sitter parse, calendar-events | next |
| P3 | views: agenda merge, then the week grid | morg-agenda-mode already does most of it |
| P4 | the outbox: create, update, delete, results, reconcile | write path proven |
| P5 | Linux importer over CalDAV or a vdir | |
| P6 | mirroring between calendars, full or busy-only, with a link map | |
| P7 | freebusy and RSVP | |

gog is dropped. It is Google-only, it is a pain to set up, the copy here is seven minor versions stale, and macOS reaches the same account for free.

## Landmines

Every one of these fails silently into an empty calendar rather than an error, which is why they are written down.

| landmine | what happens |
| --- | --- |
| the Background session | EventKit returns an empty array with no error. Check launchctl managername before believing an empty result |
| SQLite number against text | a comparison of a numeric column against a text literal never matches, and returns zero rows |
| OccurrenceCache | a bounded UI cache, not an expansion. It stopped at 2026-01 while the base tables ran to 2031 |
| CFAbsoluteTime | the SQLite path stores seconds from 2001-01-01. Add 978307200 |
| floating time zones | a floating or all-day time has no zone, and start_tz reads _float. Do not coerce it to local |
| the JXA grant callback | requestFullAccessToEventsWithCompletion never fired its block in the probe, and granted stayed null. Access still worked. Judge access by whether calendars come back, not by that flag |
| stale delete readback | after removeEventSpanError, eventWithIdentifier still returned the object. Verify a delete with a fresh store or against the SQLite file |
| the TCC row is a path | the grant is recorded against /bin/zsh as a path, client_type 1. Change the interpreter and the grant is gone |
| the schema is not a contract | Calendar.sqlitedb carries no promise across macOS releases. Probe it, do not trust it |
| no task-run! at load | the package registers verbs at load and starts nothing |
| define-list-mode! caches | a new option key needs the definition re-run. A hot reload alone does not reach the mode |

## Open decisions

1. Where the text file lives, and whether it is one file or one per month. One file is simpler, and the window bounds its size.
2. Whether the write path targets defaultCalendarForNewEvents or asks, when the account is ambiguous.
3. Whether a compos edit to the text file pushes back to the calendar, or whether the file is read-only for events and writes go through the verbs. Two-way text editing is the more Emacs answer and the more dangerous one.
4. Whether the agent runs on an interval or only on demand. On demand is cheaper and makes the file stale between uses.
