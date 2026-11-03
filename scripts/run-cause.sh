#!/usr/bin/env bash
# Says why one failed workflow run failed, as causes.jq reads it: {kind, signature}.
# collect.sh calls it for the latest run of a workflow that is red on the default
# branch. Read-only.
#
#   ./scripts/run-cause.sh <repo> <run-id>
#
# It prints the verdict and never the text: a log is untrusted, so it stays out
# of .kogut/state.json and of everything built from it. Annotations come first,
# because they are cheap and often enough. A job they do not explain has the end
# of its log read, unless the log is too big, as a device-test job's is (7 to 43
# MB): that job stays unknown, and so does any job past the first few. It exits
# 3 when a read failed, so the caller does not keep the answer.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[ $# -eq 2 ] || die "usage: run-cause.sh <repo> <run-id>"
repo="$1" run="$2"
kogut_require_repo "$repo"
[[ "$run" =~ ^[0-9]+$ ]] || die "run id must be numeric: $run"
full="$(kogut_owner)/$repo"

max_jobs=3
max_log_bytes=2000000
tail_bytes=256000
table="$KOGUT_ROOT/scripts/causes.jq"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

jobs="$(gh api "repos/$full/actions/runs/$run/jobs?filter=latest&per_page=100" \
  --jq '[.jobs[] | select(.conclusion | IN("failure", "timed_out")) | .id]')"

complete=true
read_jobs=0
: >"$tmp/jobs.json"
for job in $(jq -r '.[]' <<<"$jobs"); do
  if [ "$read_jobs" -ge "$max_jobs" ]; then
    echo '{"errors": [], "log": null}' >>"$tmp/jobs.json"
    continue
  fi
  read_jobs=$((read_jobs + 1))

  if ! errors="$(gh api "repos/$full/check-runs/$job/annotations?per_page=50" 2>/dev/null \
    --jq '[.[] | select(.annotation_level == "failure") | .message | split("\n")[0] | .[0:300]]')"; then
    errors='[]'
    complete=false
  fi
  entry="$(jq -cn --argjson errors "$errors" '{errors: $errors, log: null}')"
  if [ "$(jq -cn --argjson job "$entry" '{jobs: [$job]}' | jq -c -f "$table" | jq -r '.kind')" != unknown ]; then
    printf '%s\n' "$entry" >>"$tmp/jobs.json"
    continue
  fi

  if ! size="$(gh api --method HEAD -i "repos/$full/actions/jobs/$job/logs" 2>"$tmp/err" |
    awk 'tolower($1) == "content-length:" { n = $2 } END { print n + 0 }')"; then
    # 410 is an expired log, and it will not come back.
    grep -q 'HTTP 410' "$tmp/err" || complete=false
    printf '%s\n' "$entry" >>"$tmp/jobs.json"
    continue
  fi
  if [ "$size" -gt "$max_log_bytes" ]; then
    printf '%s\n' "$entry" >>"$tmp/jobs.json"
    continue
  fi

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
    printf '%s\n' "$entry" >>"$tmp/jobs.json"
    continue
  fi
  { grep '^##\[error\]' "$tmp/log" || true; } | tail -n 20 | sed 's/^##\[error\]//' |
    jq -Rs 'split("\n") | map(select(. != ""))' >"$tmp/errors.json"
  jq -cn --argjson annotations "$errors" --slurpfile lines "$tmp/errors.json" --rawfile log "$tmp/log" \
    '{errors: ($annotations + $lines[0]), log: $log}' >>"$tmp/jobs.json"
done

jq -s '{jobs: .}' "$tmp/jobs.json" | jq -c -f "$table"
[ "$complete" = true ] || exit 3
