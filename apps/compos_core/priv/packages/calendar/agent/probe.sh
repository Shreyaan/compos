#!/bin/zsh
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT=/Users/svs/.compos/calendar/probe-result.txt
{
  echo "session=$(launchctl managername)"
  echo "when=$(date)"
  echo "uid=$(id -u)"
  /usr/bin/osascript -l JavaScript "$DIR/probe.js" 2>&1
} > "$OUT" 2>&1
