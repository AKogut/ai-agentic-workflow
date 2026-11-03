#!/usr/bin/env bash
# Answers on a task the owner handed kogut, as the kogut App. It is for what
# kogut needs to know before it can start, or why the task is outside its
# scope: a task is maintenance or a migration, and a feature has a path of its
# own. The task then waits until the owner replies.
#
#   ./scripts/task-reply.sh <repo> <issue> [--dry-run]
#   ./scripts/task-reply.sh <repo> <issue> --plan [--dry-run]
#
# The answer is .kogut/outbox/tasks/<repo>/<issue>.md. It is scanned with
# gitleaks first, and the issue must be a task the owner labelled kogut-task.
#
# --plan posts the plan for a feature request instead, which feature.jq must say
# is owed, and marks it so the rules can tell. The plan then waits for the owner's
# label kogut-plan-approved, which this creates in case it is not there yet.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: task-reply.sh <repo> <issue> [--plan] [--dry-run]"
[ $# -ge 2 ] && [ $# -le 4 ] || die "$usage"
repo="$1" number="$2" dry_run=false plan=false
kogut_require_repo "$repo"
kogut_require_not_held "$repo"
[[ "$number" =~ ^[0-9]+$ ]] || die "an issue number is numeric: $number"
shift 2
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=true ;;
    --plan) plan=true ;;
    *) die "$usage" ;;
  esac
done
full="$(kogut_owner)/$repo"
text="$KOGUT_ROOT/.kogut/outbox/tasks/$repo/$number.md"
[ -s "$text" ] || die "the answer is missing: $text"
if [ "$plan" = true ]; then
  # Assigned first: inside [ "$(…)" = … ] a refused check would not stop the script.
  stands="$(kogut_feature_state "$full" "$repo" "$number")"
  [ "$stands" = plan ] || die "#$number does not need a plan: it says $stands"
else
  kogut_task_check "$full" "$number" >/dev/null
fi
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
if [ "$plan" = true ]; then
  # In a subshell, so GH_TOKEN goes no further than this call.
  (
    export GH_TOKEN="$token"
    kogut_ensure_label "$full" kogut-plan-approved 0e8a16 "The owner approved kogut's latest plan; only the owner's label counts"
  )
  # shellcheck disable=SC2016 # the backticks are for GitHub
  note='kogut. To let it build this, add the label `kogut-plan-approved`. To change the plan, reply here. A new plan needs a new approval.'
  marker='<!-- kogut-plan -->'
else
  # shellcheck disable=SC2016 # the backticks are for GitHub
  note='kogut, the maintenance agent. Reply here, or remove the `kogut-task` label to withdraw the task.'
  marker=''
fi
url="$(jq -n --rawfile c "$text" --arg note "$note" --arg marker "$marker" \
  '{body: "\($c | sub("\\s+$"; ""))\n\n<sub>\($note)</sub>\n\($marker)" | sub("\\s+$"; "")}' |
  GH_TOKEN="$token" gh api -X POST "repos/$full/issues/$number/comments" --input - --jq .html_url)"
mkdir -p "$KOGUT_ROOT/.kogut/sent"
mv "$text" "$KOGUT_ROOT/.kogut/sent/$(date +%Y%m%d-%H%M%S)-task-$repo-$number.md"
echo "answered: $url (as $(kogut_app_bot))"
