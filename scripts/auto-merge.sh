#!/usr/bin/env bash
# Merges, with nobody watching, the one tier of Dependabot PRs the owner agreed to
# on 2026-11-03: patches to dev dependencies past the full cooldown. It runs on a
# schedule (scripts/daily.sh), outside any Claude Code session and without the
# model. auto_merge in signals.jq decides, and merge-dependabot.sh merges, one PR
# per call, re-checks the gate and the hold, and refuses a commit other than the
# one judged here. Nothing else merges this way.
#
#   ./scripts/auto-merge.sh [--dry-run]
#
# --dry-run prints every Dependabot PR with its verdict and why, and merges and
# records nothing. A real run skips a repository on hold, merges at most
# policy.auto_merge.limit_per_repo PRs per repository per day, and records each
# outcome in .kogut/auto-merged/<YYYY-MM-DD>.jsonl, which the digest reports. It
# fails at the end when a repository could not be read or a merge was refused.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: auto-merge.sh [--dry-run]"
dry_run=false
case $# in
  0) ;;
  1)
    [ "$1" = --dry-run ] || die "$usage"
    dry_run=true
    ;;
  *) die "$usage" ;;
esac

if [ "$(jq -r '.policy.auto_merge | if type == "object" then .enabled else null end' "$KOGUT_CONFIG")" != true ]; then
  echo "auto-merge is off in kogut.config.json, so nothing merges"
  exit 0
fi
limit="$(jq -r '.policy.auto_merge.limit_per_repo // empty' "$KOGUT_CONFIG")"
[[ "$limit" =~ ^[1-9][0-9]*$ ]] || die "policy.auto_merge.limit_per_repo must be a positive number, so nothing merges"

kogut_wait_online || die "GitHub cannot be reached or gh is not logged in; nothing merged"

# A snapshot of its own, so the run's .kogut/state.json stays as it was.
state="$(mktemp)"
trap 'rm -f "$state"' EXIT
digest="$(kogut_settled_digest "$state")"

records="$KOGUT_ROOT/.kogut/auto-merged/$(date -u +%Y-%m-%d).jsonl"
record() { # repo pr head outcome reason
  mkdir -p "$(dirname "$records")"
  # shellcheck disable=SC2016 # these are jq's variables
  jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg repo "$1" --argjson pr "$2" --arg head "$3" --arg outcome "$4" --arg reason "$5" \
    '{at: $at, repo: $repo, pr: $pr, head: $head, outcome: $outcome} + (if $reason == "" then {} else {reason: $reason} end)' >>"$records"
}

left=""
while IFS= read -r repo; do
  # shellcheck disable=SC2016 # this is jq's variable
  rdigest="$(jq -c --arg r "$repo" '.repos[] | select(.name == $r)' <<<"$digest")"
  error="$(jq -r '.error // empty' <<<"$rdigest")"
  if [ -n "$error" ]; then
    echo "$repo: skipped, the collection failed: $error"
    left="$left $repo"
    continue
  fi
  if why="$(kogut_held "$repo")"; then
    echo "$repo: skipped, $why"
    continue
  fi
  if [ "$dry_run" = true ]; then
    # shellcheck disable=SC2016 # this is jq's variable
    jq -r --arg r "$repo" '.dependabot_prs | sort_by(.number)[]
      | "\($r) #\(.number) \(if .auto_merge.eligible then "yes" else "no" end): \(if .auto_merge.eligible then .title else (.auto_merge.why | join("; ")) end)"' <<<"$rdigest"
    continue
  fi

  # Today's merges count, so a second run on the same day stays under the limit. A
  # record that cannot be read counts as the limit being reached.
  merged=0
  if [ -f "$records" ]; then
    # shellcheck disable=SC2016 # this is jq's variable
    merged="$(jq -s --arg r "$repo" '[.[] | select(.repo == $r and .outcome == "merged")] | length' "$records" 2>/dev/null)" || merged="$limit"
  fi
  while IFS=$'\t' read -r number head; do
    [[ "$number" =~ ^[0-9]+$ ]] && [[ "$head" =~ ^[0-9a-f]{40}$ ]] || continue
    if [ "$merged" -ge "$limit" ]; then
      echo "$repo #$number: left for tomorrow, over the limit of $limit a day"
      record "$repo" "$number" "$head" refused "over the limit of $limit merges a day"
      continue
    fi
    if out="$("$KOGUT_ROOT/scripts/merge-dependabot.sh" "$repo" "$number" --head "$head" 2>&1 </dev/null)"; then
      printf '%s\n' "$out"
      record "$repo" "$number" "$head" merged ""
      merged=$((merged + 1))
    else
      printf '%s\n' "$out"
      record "$repo" "$number" "$head" refused "$(printf '%s\n' "$out" | tail -n 1 | sed 's/^kogut: //' | cut -c1-200)"
      left="$left $repo#$number"
    fi
  done < <(jq -r '.dependabot_prs | sort_by(.number)[] | select(.auto_merge.eligible) | [.number, .head] | @tsv' <<<"$rdigest")
done < <(jq -r '.repos[].name' <<<"$digest")
[ -z "$left" ] || die "not merged or not read:$left"
