#!/usr/bin/env bash
# The one job on a schedule (scripts/digest-schedule.sh): merges what auto-merge.sh
# may merge, then posts the digest, so the digest reports those merges. The digest
# runs even when the merges failed, and the job fails if either did.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

status=0
"$root/scripts/auto-merge.sh" || status=1
"$root/scripts/digest.sh" || status=1
exit "$status"
