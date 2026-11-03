#!/usr/bin/env bash
# Puts the daily job on a schedule with launchd, in the owner's login session.
# A run missed while the Mac sleeps happens when it wakes; one missed while it is
# off does not. The job runs scripts/daily.sh from this working copy, so it
# follows the branch checked out here, and writes to .kogut/digest.log.
#
#   ./scripts/digest-schedule.sh install [HH:MM]   # every day, 09:00 by default
#   ./scripts/digest-schedule.sh run               # once, now
#   ./scripts/digest-schedule.sh status
#   ./scripts/digest-schedule.sh uninstall
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: digest-schedule.sh install [HH:MM] | run | status | uninstall"
label="com.kogut.digest"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"
log="$KOGUT_ROOT/.kogut/digest.log"

case "${1:-}" in
  install)
    at="${2:-09:00}"
    time_re='^([01][0-9]|2[0-3]):([0-5][0-9])$'
    [[ "$at" =~ $time_re ]] || die "the time must be HH:MM: $at"
    hour=$((10#${BASH_REMATCH[1]})) minute=$((10#${BASH_REMATCH[2]}))
    case "$KOGUT_ROOT" in *[\&\<\>]*) die "this path cannot go in a plist: $KOGUT_ROOT" ;; esac
    # launchd starts jobs with a bare PATH, and Homebrew's tools are not on it.
    path="$(dirname "$(command -v gh)"):$(dirname "$(command -v jq)"):/usr/bin:/bin"
    mkdir -p "$(dirname "$plist")" "$(dirname "$log")"
    cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$KOGUT_ROOT/scripts/daily.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>$hour</integer>
    <key>Minute</key><integer>$minute</integer>
  </dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$path</string>
  </dict>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST
    plutil -lint "$plist" >/dev/null || die "the plist did not come out valid: $plist"
    launchctl bootout "$domain/$label" 2>/dev/null || true
    launchctl bootstrap "$domain" "$plist"
    echo "the daily job runs every day at $at, and logs to $log"
    ;;
  run)
    launchctl kickstart "$domain/$label"
    echo "started; it logs to $log"
    ;;
  status)
    if launchctl print "$domain/$label" >/dev/null 2>&1; then
      echo "installed: $plist"
      launchctl print "$domain/$label" | grep -E '^[[:space:]]*(state|last exit code|runs) =' || true
    else
      echo "not installed"
    fi
    if [ -f "$log" ]; then
      echo "--- last lines of $log"
      tail -n 8 "$log"
    fi
    ;;
  uninstall)
    launchctl bootout "$domain/$label" 2>/dev/null || true
    rm -f "$plist"
    echo "the daily job is off: no digest and no auto-merge"
    ;;
  *) die "$usage" ;;
esac
