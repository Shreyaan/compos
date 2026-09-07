ObjC.import("EventKit");

function run() {
  var store = $.EKEventStore.alloc.init;
  var done = false, granted = null;
  try {
    store.requestFullAccessToEventsWithCompletion(function(g, e) { granted = g; done = true; });
  } catch (ex) {
    return JSON.stringify({stage: "request", error: String(ex)});
  }
  var deadline = $.NSDate.dateWithTimeIntervalSinceNow(45);
  while (!done && $.NSDate.date.compare(deadline) < 0) {
    $.NSRunLoop.currentRunLoop.runModeBeforeDate($.NSDefaultRunLoopMode, $.NSDate.dateWithTimeIntervalSinceNow(0.25));
  }
  var cals = store.calendarsForEntityType(0);
  var names = [];
  for (var i = 0; i < cals.count; i++) names.push(ObjC.unwrap(cals.objectAtIndex(i).title));
  return JSON.stringify({done: done, granted: granted, count: Number(cals.count), names: names});
}
