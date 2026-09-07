# Calendar

A calendar for compos. Elixir owns the model, the store and the sync. Scheme
owns the views, the commands and the tools. No external program owns a
calendar.

This file is the package source. Each heading that carries a tangle header
writes its block to the named file.

## Why not one MCP server per provider

An MCP server per provider is a tool zoo. Two accounts on two providers give
four servers and four vocabularies, and no one of them holds a merged view.
An MCP server is also a chat door only. It cannot draw a week, it cannot hold
an edit made offline, and it cannot merge two calendars.

The calendar gets one tool surface through define-tool!. The compos MCP
server then serves that surface to an outside agent. One vocabulary, every
provider behind it.

## Why not a wrapper over khal or vdirsyncer

Such a program owns the event model and the store. We would parse its output,
fight its schema and inherit its recurrence faults. The store is the part we
must own, because the store is where a lost edit happens.

## Where gog fits

gog is a Google command line tool. It already holds multi-account OAuth in a
keyring, and it answers JSON. Phase 2 calls it for Google reads, so that
phase needs no OAuth work.

gog is not a calendar wrapper. It owns no model and no store. It answers one
request. Phase 7 replaces it with a native flow over Req, and the dependency
goes away.

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

    Providers Google   REST v3 through gog, later a native flow
              CalDAV   iCloud, Fastmail, Nextcloud
              ICS      a read-only subscription URL
              Local    a calendar compos owns; no remote
              Morg     agenda.scm dated headings, read-only

Every provider answers the same records. A view never knows which provider a
record came from.

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

The raw component is kept. Every property we do not model survives a round
trip. A round trip that loses a property is a fault.

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

occurrences holds the expanded recurrences for a rolling window, about one
year back and two years forward. A view asks one indexed range query. It
never expands a rule while it draws. A write to events expands only that
event again.

outbox means an edit made offline is not lost. conflicts means a clash is
shown, and never resolved in silence.

## Sync

Pull, per provider:

- Google answers an incremental list for a syncToken. A 410 answer means the
  token expired, and the source must do a full resync. This case happens.
  Handle it.
- CalDAV uses sync-collection with a sync-token (RFC 6578). Where a server
  does not support it, fall back to the collection ctag, then a PROPFIND of
  the hrefs and their ETags, then a multiget of the changed hrefs.
- An ICS URL uses a conditional GET with ETag or Last-Modified. On a change,
  parse the whole file and compare by UID.

Push:

The outbox drains in order. Each write carries If-Match with the stored ETag.
A 412 or a 409 answer means the remote changed first. The write then goes to
conflicts and the user sees a card. A user edit is never dropped.

Conflict rule: a field the user did not touch takes the remote value. A field
that both sides changed makes a conflict row.

A source syncs on a timer, on a manual refresh, and when its buffer wakes.
Sync runs off the Session lane through task-run!. Backoff is exponential on
an error, and it resets on a success.

## Mirroring

Mirroring is not provider sync. It is a rule between two local sources.

    (calendar-mirror-add! 'work 'personal 'busy)

A rule states a source, a target and a mode. full copies the details. busy
copies a block with no title. tagged copies only the events that carry a tag.

links holds the identity map, so a second run updates the copy and does not
add a second one. A mirrored event carries X-COMPOS-MIRROR-OF, and a mirrored
event is never mirrored again. Two rules in opposite directions cannot loop.

## Two dependency decisions

Time zones. Elixir ships a UTC-only time zone database. A DTSTART with a TZID
cannot be resolved without a real one. Add tz, which is small and compiles
the IANA data, and set config :elixir, :time_zone_database. This is not
optional. Every recurrence across a daylight saving change is wrong without
it.

Recurrence. No suitable library is in the tree, and cocktail does not model
RFC 5545 directly. Write Calendar.RRule. It is pure, it is about 400 lines,
and it is table tested against the RFC 5545 examples. Cover FREQ daily,
weekly, monthly and yearly, then INTERVAL, BYDAY, BYMONTHDAY, BYMONTH,
BYSETPOS, COUNT, UNTIL and WKST, then EXDATE, RDATE and the RECURRENCE-ID
overrides. The overrides are the part that real calendars use, and the part
that libraries get wrong.
