#!/bin/zsh
# Drains the calendar spool. launchd wakes this when a request file lands.
setopt null_glob
DIR="$(cd "$(dirname "$0")" && pwd)"
SPOOL="$HOME/.compos/calendar"
mkdir -p "$SPOOL/outbox" "$SPOOL/results"
print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $(launchctl managername)" > "$SPOOL/last-drain"
for req in "$SPOOL"/outbox/*.json; do
  id="$(basename "$req" .json)"
  /usr/bin/osascript -l JavaScript "$DIR/calendar.js" "$req" > "$SPOOL/results/$id.part" 2>"$SPOOL/results/$id.err"
  mv "$SPOOL/results/$id.part" "$SPOOL/results/$id.json"
  rm -f "$req"
done
