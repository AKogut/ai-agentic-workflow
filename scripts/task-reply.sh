#!/usr/bin/env bash
# Answers on a task the owner handed kogut, as the kogut App. It is for what
# kogut needs to know before it can start, or why the task is outside its
# scope: maintenance and migrations, never features. The task then waits until
# the owner replies.
#
#   ./scripts/task-reply.sh <repo> <issue> [--dry-run]
#
# The answer is .kogut/outbox/tasks/<repo>/<issue>.md. It is scanned with
# gitleaks first, and the issue must be a task the owner labelled kogut-task.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: task-reply.sh <repo> <issue> [--dry-run]"
[ $# -ge 2 ] && [ $# -le 3 ] || die "$usage"
repo="$1" number="$2" dry_run=false
kogut_require_repo "$repo"
[[ "$number" =~ ^[0-9]+$ ]] || die "an issue number is numeric: $number"
if [ $# -eq 3 ]; then
  [ "$3" = --dry-run ] || die "$usage"
  dry_run=true
fi
full="$(kogut_owner)/$repo"
text="$KOGUT_ROOT/.kogut/outbox/tasks/$repo/$number.md"
[ -s "$text" ] || die "the answer is missing: $text"
kogut_task_check "$full" "$number" >/dev/null
kogut_scan <"$text" || die "gitleaks flagged the answer; nothing was sent"

if [ "$dry_run" = true ]; then
  echo "answer on https://github.com/$full/issues/$number, as $(kogut_app_bot)"
  echo "---"
  cat "$text"
  echo "not sent: --dry-run"
  exit 0
fi

# Checked before use: an empty GH_TOKEN would make gh write as the owner.
token="$(kogut_app_token "$repo")"
[ -n "$token" ] || die "no token from the kogut App for $repo"
url="$(jq -n --rawfile c "$text" \
  '{body: "\($c | sub("\\s+$"; ""))\n\n<sub>kogut, the maintenance agent. Reply here, or remove the `kogut-task` label to withdraw the task.</sub>"}' |
  GH_TOKEN="$token" gh api -X POST "repos/$full/issues/$number/comments" --input - --jq .html_url)"
mkdir -p "$KOGUT_ROOT/.kogut/sent"
mv "$text" "$KOGUT_ROOT/.kogut/sent/$(date +%Y%m%d-%H%M%S)-task-$repo-$number.md"
echo "answered: $url (as $(kogut_app_bot))"
