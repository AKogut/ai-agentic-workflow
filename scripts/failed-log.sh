#!/usr/bin/env bash
# Prints the part of a failed workflow run that explains the failure: which
# jobs and steps failed, then the log lines leading up to each error.
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

gh run view "$run" -R "$full" --json workflowName,event,conclusion,createdAt,headSha,url,jobs --jq '
  "\(.workflowName) · \(.event) · \(.conclusion) · \(.createdAt) · \(.headSha[0:7])",
  .url,
  "",
  (.jobs[] | select(.conclusion | IN("success", "skipped") | not)
    | "✗ \(.name) (\(.conclusion))",
      (.steps[] | select(.conclusion == "failure") | "    step \(.number): \(.name)"))'
echo

# Log lines are "job<TAB>step<TAB>timestamp text". Drop the timestamp, colours,
# blank lines and checkout/credential cleanup noise, and print the lines leading
# up to each ##[error]; the first few errors are the ones that explain the run.
gh run view "$run" -R "$full" --log-failed | awk -F'\t' -v ctx="$context" '
  {
    job = $1
    line = $0
    sub(/^[^\t]*\t[^\t]*\t/, "", line)
    sub(/^[0-9-]+T[0-9:.]+Z ?/, "", line)
    # Colours arrive either as real escapes or spelled out as "^[[31m".
    gsub(/(\033|\^\[)\[[0-9;]*m/, "", line)
    if (line ~ /^[ \t]*$/ || line ~ /^\[command\]\/usr\/bin\/git / || line ~ /^##\[endgroup\]/ || line ~ /git-credentials|includeif|extraheader/) next
    sub(/^##\[group\]/, "> ", line)
    buf[n++ % ctx] = line
    if (line ~ /^##\[error\]/) {
      print "──── " job
      for (i = (n > ctx ? n - ctx : 0); i < n; i++) print buf[i % ctx]
      print ""
      n = 0
      if (++errors >= 5) { print "(stopped after 5 errors)"; exit }
    }
  }'
