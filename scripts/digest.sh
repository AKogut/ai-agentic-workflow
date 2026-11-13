#!/usr/bin/env bash
# Posts the daily digest: each repository's state to its own Discord channel,
# then one summary of every repository to the summary channel, if .env names one.
# It runs on a schedule (scripts/digest-schedule.sh), outside any Claude Code
# session: collect.sh reads GitHub, digest.jq and summary.jq render, notify.sh
# delivers. No model and no App token are involved, and nothing on GitHub changes.
# It also says which repositories are on hold and what auto-merge.sh did today.
# Acting on a digest is what /kogut is for.
#
#   ./scripts/digest.sh [--dry-run] [repo ...]
#
# --dry-run prints the reports and the summary, and posts nothing. A run that
# names repositories posts no summary, since the summary is of every repository.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

dry_run=false
if [ "${1:-}" = --dry-run ]; then
  dry_run=true
  shift
fi

kogut_wait_online || die "GitHub cannot be reached or gh is not logged in; no digest was posted"

# A snapshot of its own, so the run's .kogut/state.json stays as it was.
state="$(mktemp)"
trap 'rm -f "$state"' EXIT
digest="$(kogut_settled_digest "$state" "$@")"

holds='{}'
while IFS= read -r repo; do
  if why="$(kogut_held "$repo")"; then
    holds="$(jq -c --arg r "$repo" --arg w "$why" '. + {($r): $w}' <<<"$holds")"
  fi
done < <(jq -r '.repos[].name' <<<"$digest")

auto='[]'
records="$KOGUT_ROOT/.kogut/auto-merged/$(date -u +%Y-%m-%d).jsonl"
if [ -f "$records" ]; then
  auto="$(jq -cs . "$records" 2>/dev/null)" || auto='[]'
fi

input="$(jq -c --argjson holds "$holds" --argjson auto "$auto" '. + {holds: $holds, auto_merged: $auto}' <<<"$digest")"
reports="$(jq -c -f "$KOGUT_ROOT/scripts/digest.jq" <<<"$input")"

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

# The summary comes last, so it can never cost a repository its report.
if ! summary="$(jq -c --argjson reports "$reports" -f "$KOGUT_ROOT/scripts/summary.jq" <<<"$input")"; then
  failed="$failed summary"
elif [ "$dry_run" = true ]; then
  echo "--- summary ($(jq -r .status <<<"$summary"))"
  jq -r .text <<<"$summary"
elif [ $# -gt 0 ]; then
  echo "summary not sent: this run covers only some repositories"
else
  jq -r .text <<<"$summary" >"$KOGUT_OUTBOX/summary.md"
  "$KOGUT_ROOT/scripts/notify.sh" --summary "$(jq -r .status <<<"$summary")" </dev/null || failed="$failed summary"
fi
[ -z "$failed" ] || die "the digest was not posted for:$failed"
