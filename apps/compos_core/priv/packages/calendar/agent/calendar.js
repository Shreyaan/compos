// The only thing that touches EventKit. Runs in the Aqua session, driven by
// the LaunchAgent, one request file at a time. Read operations only.

ObjC.import("EventKit");

function readText(path) {
  var s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  return ObjC.unwrap(s);
}

function dateFrom(text, endOfDay) {
  var parts = text.split("-");
  var d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
  if (endOfDay) d.setHours(23, 59, 59, 0);
  return $.NSDate.dateWithTimeIntervalSince1970(d.getTime() / 1000);
}

function fmt(pattern) {
  var f = $.NSDateFormatter.alloc.init;
  f.dateFormat = pattern;
  return f;
}

function calendarRows(store) {
  var cals = store.calendarsForEntityType(0);
  var rows = [];
  for (var i = 0; i < cals.count; i++) {
    var c = cals.objectAtIndex(i);
    rows.push({
      id: ObjC.unwrap(c.calendarIdentifier),
      title: ObjC.unwrap(c.title),
      account: ObjC.unwrap(c.source.title),
      writable: c.allowsContentModifications ? true : false
    });
  }
  return rows;
}

function wanted(store, names) {
  var cals = store.calendarsForEntityType(0);
  if (!names || names.length === 0) return cals;
  var keep = $.NSMutableArray.alloc.init;
  for (var i = 0; i < cals.count; i++) {
    var c = cals.objectAtIndex(i);
    var cid = ObjC.unwrap(c.calendarIdentifier);
    if (names.indexOf(cid) >= 0 || names.indexOf(ObjC.unwrap(c.title)) >= 0) keep.addObject(c);
  }
  return keep.count > 0 ? keep : cals;
}

function eventRows(store, from, to, names) {
  var day = fmt("yyyy-MM-dd"), time = fmt("HH:mm"), stamp = fmt("yyyy-MM-dd HH:mm");
  var weekday = fmt("EEEE");
  var pred = store.predicateForEventsWithStartDateEndDateCalendars(
    dateFrom(from, false), dateFrom(to, true), wanted(store, names));
  var found = store.eventsMatchingPredicate(pred);
  var rows = [];
  for (var i = 0; i < found.count; i++) {
    var e = found.objectAtIndex(i);
    var allDay = e.allDay ? true : false;
    rows.push({
      uid: ObjC.unwrap(e.calendarItemExternalIdentifier),
      event_id: ObjC.unwrap(e.eventIdentifier),
      summary: ObjC.unwrap(e.title),
      location: ObjC.unwrap(e.location),
      calendar: ObjC.unwrap(e.calendar.title),
      account: ObjC.unwrap(e.calendar.source.title),
      all_day: allDay,
      day: ObjC.unwrap(day.stringFromDate(e.startDate)),
      weekday: ObjC.unwrap(weekday.stringFromDate(e.startDate)),
      starts: allDay ? null : ObjC.unwrap(time.stringFromDate(e.startDate)),
      ends: allDay ? null : ObjC.unwrap(time.stringFromDate(e.endDate)),
      starts_at: ObjC.unwrap(stamp.stringFromDate(e.startDate)),
      ends_at: ObjC.unwrap(stamp.stringFromDate(e.endDate)),
      recurring: e.hasRecurrenceRules ? true : false,
      attendees: e.attendees ? Number(e.attendees.count) : 0,
      url: e.URL ? ObjC.unwrap(e.URL.absoluteString) : null
    });
  }
  rows.sort(function (a, b) { return a.starts_at < b.starts_at ? -1 : 1; });
  return rows;
}

function stampFrom(text) {
  var parts = String(text).split(" ");
  var d = parts[0].split("-");
  var t = parts.length > 1 ? parts[1].split(":") : ["0", "0"];
  var js = new Date(Number(d[0]), Number(d[1]) - 1, Number(d[2]),
                    Number(t[0]), Number(t[1]), 0);
  return $.NSDate.dateWithTimeIntervalSince1970(js.getTime() / 1000);
}

function findCalendar(store, ref) {
  if (!ref) return store.defaultCalendarForNewEvents;
  var cals = store.calendarsForEntityType(0);
  for (var i = 0; i < cals.count; i++) {
    var c = cals.objectAtIndex(i);
    if (ObjC.unwrap(c.calendarIdentifier) === ref || ObjC.unwrap(c.title) === ref) {
      return c.allowsContentModifications ? c : null;
    }
  }
  return null;
}

function createEvent(store, req) {
  if (!req.title || !req.start || !req.end) {
    return {ok: false, error: "create needs title, start and end"};
  }
  var cal = findCalendar(store, req.calendar);
  if (!cal) return {ok: false, error: "no writable calendar named " + String(req.calendar)};
  var ev = $.EKEvent.eventWithEventStore(store);
  ev.title = req.title;
  ev.calendar = cal;
  ev.startDate = stampFrom(req.start);
  ev.endDate = stampFrom(req.end);
  if (req.all_day) ev.allDay = true;
  if (req.notes) ev.notes = req.notes;
  if (req.location) ev.location = req.location;
  var err = Ref();
  var saved = store.saveEventSpanError(ev, 0, err);
  if (!saved) return {ok: false, error: "the save was refused"};
  var stamp = fmt("yyyy-MM-dd HH:mm");
  return {ok: true, op: "create",
          uid: ObjC.unwrap(ev.calendarItemExternalIdentifier),
          event_id: ObjC.unwrap(ev.eventIdentifier),
          calendar: ObjC.unwrap(cal.title),
          account: ObjC.unwrap(cal.source.title),
          summary: ObjC.unwrap(ev.title),
          starts_at: ObjC.unwrap(stamp.stringFromDate(ev.startDate)),
          ends_at: ObjC.unwrap(stamp.stringFromDate(ev.endDate))};
}

// Removal names one event and states what it expects to find there. A title
// that does not match means the identifier moved, so nothing is removed.
function removeEvent(store, req) {
  if (!req.event_id || !req.expect) {
    return {ok: false, error: "remove needs event_id and expect"};
  }
  var ev = store.eventWithIdentifier(req.event_id);
  if (!ev || ObjC.unwrap(ev) === null) return {ok: false, error: "no such event"};
  var found = ObjC.unwrap(ev.title);
  if (found !== req.expect) {
    return {ok: false, error: "expected " + req.expect + " but found " + found};
  }
  var err = Ref();
  var gone = store.removeEventSpanError(ev, 0, err);
  return {ok: gone ? true : false, op: "remove", event_id: req.event_id, summary: found};
}

function run(argv) {
  var req;
  try {
    req = JSON.parse(readText(argv[0]));
  } catch (ex) {
    return JSON.stringify({ok: false, error: "unreadable request: " + String(ex)});
  }
  var store = $.EKEventStore.alloc.init;
  var cals = store.calendarsForEntityType(0);
  if (cals.count === 0) {
    return JSON.stringify({ok: false, error: "no calendar access in this session"});
  }
  try {
    if (req.op === "calendars") {
      return JSON.stringify({ok: true, op: req.op, calendars: calendarRows(store)});
    }
    if (req.op === "events") {
      return JSON.stringify({ok: true, op: req.op, from: req.from, to: req.to,
                             events: eventRows(store, req.from, req.to, req.calendars)});
    }
    if (req.op === "create") return JSON.stringify(createEvent(store, req));
    if (req.op === "remove") return JSON.stringify(removeEvent(store, req));
    return JSON.stringify({ok: false, error: "unknown op: " + String(req.op)});
  } catch (ex) {
    return JSON.stringify({ok: false, op: req.op, error: String(ex)});
  }
}
