ObjC.import("EventKit");

function run() {
  var store = $.EKEventStore.alloc.init;
  var cals = store.calendarsForEntityType(0);
  if (cals.count == 0) return JSON.stringify({error: "no calendar access"});
  var cal = store.defaultCalendarForNewEvents;
  if (!cal || cal.js === undefined && ObjC.unwrap(cal) === null) return JSON.stringify({error: "no default calendar"});
  var ev = $.EKEvent.eventWithEventStore(store);
  ev.title = "compos write probe";
  ev.notes = "created by the compos calendar write probe; safe to delete";
  ev.startDate = $.NSDate.dateWithTimeIntervalSinceNow(3600);
  ev.endDate = $.NSDate.dateWithTimeIntervalSinceNow(5400);
  ev.calendar = cal;
  var e1 = Ref();
  var created = store.saveEventSpanError(ev, 0, e1);
  var id = ObjC.unwrap(ev.eventIdentifier);
  var back = null;
  if (created && id) {
    var got = store.eventWithIdentifier(id);
    if (got) back = ObjC.unwrap(got.title);
  }
  var e2 = Ref();
  var deleted = false;
  if (created) deleted = store.removeEventSpanError(ev, 0, e2);
  var gone = id ? (store.eventWithIdentifier(id) === null || ObjC.unwrap(store.eventWithIdentifier(id)) === null) : null;
  return JSON.stringify({calendar: ObjC.unwrap(cal.title), source: ObjC.unwrap(cal.source.title), created: created, id: id, readback: back, deleted: deleted, gone: gone});
}
