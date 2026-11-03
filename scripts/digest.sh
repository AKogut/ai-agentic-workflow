#!/usr/bin/env bash
# Posts the daily digest: each repository's state to its own Discord channel.
# It runs on a schedule (scripts/digest-schedule.sh), outside any Claude Code
# session: collect.sh reads GitHub, digest.jq renders, notify.sh delivers. No
# model and no App token are involved, and nothing on GitHub changes. Acting on
# a digest is what /kogut is for.
#
#   ./scripts/digest.sh [--dry-run] [repo ...]
#
# --dry-run prints the reports and posts nothing.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

dry_run=false
if [ "${1:-}" = --dry-run ]; then
  dry_run=true
  shift
fi

# A scheduled run starts right after the Mac wakes, before the network is back.
online=false
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if gh api rate_limit --silent 2>/dev/null; then
    online=true
    break
  fi
  sleep 30
done
[ "$online" = true ] || die "GitHub cannot be reached or gh is not logged in; no digest was posted"

# A snapshot of its own, so the run's .kogut/state.json stays as it was.
state="$(mktemp)"
trap 'rm -f "$state"' EXIT
digest="$(KOGUT_STATE="$state" "$KOGUT_ROOT/scripts/collect.sh" "$@")"

# GitHub works out mergeability when asked, so a first read can say UNKNOWN.
if jq -e 'any(.repos[].dependabot_prs[]?; .mergeable == "UNKNOWN")' <<<"$digest" >/dev/null; then
  sleep 30
  digest="$(KOGUT_STATE="$state" "$KOGUT_ROOT/scripts/collect.sh" "$@")"
fi

reports="$(jq -c -f "$KOGUT_ROOT/scripts/digest.jq" <<<"$digest")"

# Its own outbox, so a digest cannot send or overwrite a report a /kogut run wrote.
export KOGUT_OUTBOX="$KOGUT_ROOT/.kogut/digest"
mkdir -p "$KOGUT_OUTBOX"
failed=""
while IFS=$'\t' read -r repo status; do
  if [ "$dry_run" = true ]; then
    echo "--- $repo ($status)"
    jq -r --arg r "$repo" '.[] | select(.name == $r) | .text' <<<"$reports"
    continue
  fi
  jq -r --arg r "$repo" '.[] | select(.name == $r) | .text' <<<"$reports" >"$KOGUT_OUTBOX/$repo.md"
  "$KOGUT_ROOT/scripts/notify.sh" "$repo" "$status" </dev/null || failed="$failed $repo"
done < <(jq -r '.[] | [.name, .status] | @tsv' <<<"$reports")
[ -z "$failed" ] || die "the digest was not posted for:$failed"
