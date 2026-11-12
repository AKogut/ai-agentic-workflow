#!/usr/bin/env bash
# Says why one failed workflow run failed, as causes.jq reads it: {kind, signature}.
# collect.sh calls it for the latest run of a workflow that is red on the default
# branch. Read-only.
#
#   ./scripts/run-cause.sh <repo> <run-id>
#
# It prints the verdict and never the text: a log is untrusted, so it stays out
# of .kogut/state.json and of everything built from it. A run is only as
# explained as its least explained job, so every failed job has to be read: in
# ephemeral 42583637532 kind's download failed all five cluster jobs, and the
# two left unread kept the run unknown while only three were. Annotations come
# first, for every failed job, because they are cheap and often enough, and a
# refused token shows there. A job they do not explain has the end of its log
# read, one job per failed step before a second job of the same step, because a
# different step is likelier to have failed differently. The first job that
# stays unexplained ends the reading, since the run cannot be explained any
# more: so does a log too big to read, as a device-test job's is (7 to 43 MB),
# or one past the budget for the whole run. It exits 3 when a read failed, so
# the caller does not keep the answer.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[ $# -eq 2 ] || die "usage: run-cause.sh <repo> <run-id>"
repo="$1" run="$2"
kogut_require_repo "$repo"
[[ "$run" =~ ^[0-9]+$ ]] || die "run id must be numeric: $run"
full="$(kogut_owner)/$repo"

# Annotations for up to max_jobs failed jobs, and a run with more is unknown.
# Logs up to max_total_bytes in all, which is three logs at max_log_bytes, the
# most a run cost when no more than three of its jobs were read.
max_jobs=20
max_log_bytes=2000000
max_total_bytes=6000000
tail_bytes=256000
table="$KOGUT_ROOT/scripts/causes.jq"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The verdict on the job entries in the files named, and its kind alone.
cause_of() { jq -s '{jobs: .}' "$@" | jq -c -f "$table"; }
kind_of() { cause_of "$@" | jq -r '.kind'; }

# Failed jobs in the order their logs are read: the first job of each failed
# step, then the second of each, and so on, in GitHub's order otherwise. A job
# with no failed step is a step of its own.
order="$(gh api "repos/$full/actions/runs/$run/jobs?filter=latest&per_page=100" \
  --jq '[.jobs[] | select(.conclusion | IN("failure", "timed_out"))
          | {id, step: ([.steps[]? | select(.conclusion == "failure") | .name][0] // "job \(.id)")}]')"
order="$(jq -r '. as $jobs
  | [range(length) as $i | $jobs[$i] + {i: $i, nth: ([$jobs[:$i][] | select(.step == $jobs[$i].step)] | length)}]
  | sort_by(.nth, .i) | .[].id' <<<"$order")"

complete=true
stop=false
entries=()
for job in $order; do
  entries+=("$tmp/$job.json")
  if [ "${#entries[@]}" -gt "$max_jobs" ]; then
    echo '{"errors": [], "log": null}' >"$tmp/$job.json"
    stop=true
    continue
  fi
  if ! errors="$(gh api "repos/$full/check-runs/$job/annotations?per_page=50" 2>/dev/null \
    --jq '[.[] | select(.annotation_level == "failure") | .message | split("\n")[0] | .[0:300]]')"; then
    errors='[]'
    complete=false
  fi
  jq -cn --argjson errors "$errors" '{errors: $errors, log: null}' >"$tmp/$job.json"
done
if [ "${#entries[@]}" -eq 0 ]; then
  echo '{"jobs": []}' | jq -c -f "$table"
  exit 0
fi
# Nothing outranks a refused token, so no log can change that answer.
[ "$(kind_of "${entries[@]}")" != credentials ] || stop=true

spent=0
for entry in "${entries[@]}"; do
  [ "$stop" = false ] || break
  [ "$(kind_of "$entry")" = unknown ] || continue
  job="$(basename "$entry" .json)"
  stop=true

  if ! size="$(gh api --method HEAD -i "repos/$full/actions/jobs/$job/logs" 2>"$tmp/err" |
    awk 'tolower($1) == "content-length:" { n = $2 } END { print n + 0 }')"; then
    # 410 is an expired log, and it will not come back.
    grep -q 'HTTP 410' "$tmp/err" || complete=false
    continue
  fi
  # A log whose size GitHub did not say is charged as one at the limit.
  [ "$size" -gt 0 ] || size="$max_log_bytes"
  if [ "$size" -gt "$max_log_bytes" ] || [ $((spent + size)) -gt "$max_total_bytes" ]; then
    continue
  fi
  spent=$((spent + size))

  # head stops a log whose size GitHub did not say, and gh may die of SIGPIPE
  # then, so an empty result is the test of a failed read.
  { gh api "repos/$full/actions/jobs/$job/logs" 2>/dev/null || true; } |
    head -c "$max_log_bytes" | tail -c "$tail_bytes" | tr -d '\000' |
    awk '{
        line = $0
        sub(/^[0-9-]+T[0-9:.]+Z ?/, "", line)
        gsub(/(\033|\^\[)\[[0-9;]*m/, "", line)
        print substr(line, 1, 2000)
      }' >"$tmp/log" || true
  if [ ! -s "$tmp/log" ]; then
    complete=false
    continue
  fi
  { grep '^##\[error\]' "$tmp/log" || true; } | tail -n 20 | sed 's/^##\[error\]//' |
    jq -Rs 'split("\n") | map(select(. != ""))' >"$tmp/errors.json"
  jq -c --slurpfile lines "$tmp/errors.json" --rawfile log "$tmp/log" \
    '{errors: (.errors + $lines[0]), log: $log}' "$entry" >"$tmp/read"
  mv "$tmp/read" "$entry"
  # The run is unknown once one job is, and a refused token is the answer.
  case "$(kind_of "$entry")" in
    unknown | credentials) ;;
    *) stop=false ;;
  esac
done

cause_of "${entries[@]}"
[ "$complete" = true ] || exit 3
