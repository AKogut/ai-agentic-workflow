#!/usr/bin/env bash
# The one job on a schedule (scripts/digest-schedule.sh): merges what auto-merge.sh
# may merge, then posts the digest, so the digest reports those merges. The digest
# runs even when the merges failed, and the job fails if either did.
#
#   ./scripts/daily.sh                    # once, now
#   ./scripts/daily.sh --catch-up HH:MM   # once a day, at HH:MM or at the first start after it
#
# launchd never makes up a run missed while the Mac is off, so it starts the job
# at HH:MM, at login and every hour, and --catch-up decides whether a start does
# anything: nothing before HH:MM local time, and nothing once a run has started
# today. A run counts from the moment GitHub can be reached, however it was
# started, and one that cannot reach GitHub leaves the day to the next start.
# `digest-schedule.sh run` leaves .kogut/daily-run-now, and the next start runs
# whatever the time and the day's run say.
set -uo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: daily.sh [--catch-up HH:MM]"
catch_up=""
case $# in
  0) ;;
  2)
    [ "$1" = --catch-up ] || die "$usage"
    [[ "$2" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "the time must be HH:MM: $2"
    catch_up="$2"
    ;;
  *) die "$usage" ;;
esac

# Local time, which the schedule is in. Tests pin it with KOGUT_LOCAL_NOW.
now="${KOGUT_LOCAL_NOW:-$(date '+%Y-%m-%d %H:%M')}"
[[ "$now" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] || die "the local time must be YYYY-MM-DD HH:MM: $now"
today="${now% *}"
ran="$KOGUT_ROOT/.kogut/daily-last-run"
asked="$KOGUT_ROOT/.kogut/daily-run-now"

if [ -n "$catch_up" ]; then
  if [ -e "$asked" ]; then
    rm -f "$asked"
  elif [[ "${now#* }" < "$catch_up" ]] || [ "$(cat "$ran" 2>/dev/null)" = "$today" ]; then
    exit 0
  fi
fi

echo "--- daily run, $now"
if ! kogut_wait_online; then
  echo "GitHub cannot be reached, or it refused whom kogut reads as (policy.read_as); nothing ran${catch_up:+, and the next start tries again}"
  exit 1
fi
mkdir -p "$(dirname "$ran")"
echo "$today" >"$ran"

status=0
"$KOGUT_ROOT/scripts/auto-merge.sh" || status=1
"$KOGUT_ROOT/scripts/digest.sh" || status=1
exit "$status"
