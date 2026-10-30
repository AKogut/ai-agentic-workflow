#!/usr/bin/env bash
# Prints the part of a failed workflow run that explains the failure: which
# jobs and steps failed, then for each failed job its error annotations and the
# log lines leading up to each error.
#
#   ./scripts/failed-log.sh <repo> <run-id> [context-lines]
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[ $# -ge 2 ] || die "usage: failed-log.sh <repo> <run-id> [context-lines]"
repo="$1" run="$2" context="${3:-50}"
kohut_require_repo "$repo"
[[ "$run" =~ ^[0-9]+$ ]] || die "run id must be numeric: $run"
[[ "$context" =~ ^[0-9]+$ ]] || die "context-lines must be numeric: $context"
full="$(kohut_owner)/$repo"

# Job logs download at a few hundred KB a second, and a device-test job can
# log 40 MB. Past the limit the annotations and the failed steps have to do.
max_jobs=3
max_log_bytes=5000000

meta="$(gh run view "$run" -R "$full" --json workflowName,event,conclusion,createdAt,headSha,url,jobs)"
jq -r '
  "\(.workflowName) · \(.event) · \(.conclusion) · \(.createdAt) · \(.headSha[0:7])",
  .url,
  "",
  (.jobs[] | select(.conclusion | IN("success", "skipped") | not)
    | "✗ \(.name) (\(.conclusion))",
      (.steps[] | select(.conclusion == "failure") | "    step \(.number): \(.name)"))' <<<"$meta"
echo

# Log lines are "timestamp text". Drop the timestamp, colours, blank lines and
# checkout/credential cleanup noise, and print the lines leading up to each
# ##[error]; the first few errors are the ones that explain the job.
excerpt() {
  awk -v ctx="$context" '
    {
      line = $0
      sub(/^[0-9-]+T[0-9:.]+Z ?/, "", line)
      # Colours arrive either as real escapes or spelled out as "^[[31m".
      gsub(/(\033|\^\[)\[[0-9;]*m/, "", line)
      if (line ~ /^[ \t]*$/ || line ~ /^\[command\]\/usr\/bin\/git / || line ~ /^##\[endgroup\]/ || line ~ /git-credentials|includeif|extraheader/) next
      sub(/^##\[group\]/, "> ", line)
      buf[n++ % ctx] = line
      if (line ~ /^##\[error\]/) {
        for (i = (n > ctx ? n - ctx : 0); i < n; i++) print buf[i % ctx]
        print ""
        n = 0
        if (++errors >= 5) { print "(stopped after 5 errors)"; exit }
      }
    }'
}

err="$(mktemp)"
trap 'rm -f "$err"' EXIT
shown=0
while IFS=$'\t' read -r job name url; do
  [ -n "$job" ] || continue
  if [ "$shown" -ge "$max_jobs" ]; then
    echo "(stopped after $max_jobs failed jobs)"
    break
  fi
  shown=$((shown + 1))
  echo "──── $name"

  # Test reporters and ::error:: lines leave annotations. The runner adds an
  # "exit code" one to every failed job, which says nothing.
  gh api "repos/$full/check-runs/$job/annotations" --jq '.[]
    | select(.annotation_level == "failure" and (.message | test("exit code [0-9]+\\.?$") | not))
    | "annotation: \(.message | split("\n")[0] | .[0:300])"' 2>/dev/null || true

  if ! size="$(gh api --method HEAD -i "repos/$full/actions/jobs/$job/logs" 2>"$err" |
    awk 'tolower($1) == "content-length:" { n = $2 } END { print n + 0 }')"; then
    if grep -q 'HTTP 410' "$err"; then
      echo "(the log has expired)"
    else
      echo "(no log: $(head -n 1 "$err"))"
    fi
    echo
    continue
  fi
  if [ "$size" -gt "$max_log_bytes" ]; then
    echo "(the log is $((size / 1000000)) MB, over the $((max_log_bytes / 1000000)) MB limit: $url)"
    echo
    continue
  fi

  # awk stops reading after five errors, so gh may die of SIGPIPE; what was
  # printed is all that is needed.
  out="$(gh api "repos/$full/actions/jobs/$job/logs" 2>/dev/null | excerpt)" || true
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    echo "(no ##[error] in the log)"
  fi
  echo
done < <(jq -r '.jobs[] | select(.conclusion | IN("success", "skipped") | not) | [.databaseId, .name, .url] | @tsv' <<<"$meta")
