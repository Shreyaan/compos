#!/bin/zsh
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT=/Users/svs/.compos/calendar/write-result.txt
{
  echo "session=$(launchctl managername)"
  /usr/bin/osascript -l JavaScript "$DIR/write-probe.js" 2>&1
} > "$OUT" 2>&1
