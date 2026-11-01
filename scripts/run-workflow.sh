#!/usr/bin/env bash
# Acts on a workflow of a watched repository's default branch, as the kogut
# App, and only as the rules in signals.jq name for it:
#   rerun     retries the failed jobs of the workflow's latest run
#   dispatch  starts the workflow at the head of the default branch
#   enable    turns on a workflow GitHub disabled for inactivity
# The state is collected afresh first, so the decision never rests on an old
# snapshot.
#
#   ./scripts/run-workflow.sh <repo> <workflow file> <rerun|dispatch|enable> [--dry-run]
#
# <workflow file> is the path the digest shows, .github/workflows/<name>.yml.
# The App's token for this carries actions: write and nothing else. A dispatch
# always runs the default branch, with no inputs.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: run-workflow.sh <repo> <workflow file> <rerun|dispatch|enable> [--dry-run]"
[ $# -ge 3 ] && [ $# -le 4 ] || die "$usage"
repo="$1" path="$2" action="$3" dry_run=false
kogut_require_repo "$repo"
[[ "$path" =~ ^\.github/workflows/[A-Za-z0-9._-]+\.ya?ml$ ]] || die "not a workflow file: $path"
case "$action" in rerun | dispatch | enable) ;; *) die "$usage" ;; esac
if [ $# -eq 4 ]; then
  [ "$4" = --dry-run ] || die "$usage"
  dry_run=true
fi
full="$(kogut_owner)/$repo"

# A snapshot of its own, so the run's .kogut/state.json stays as it was.
state="$(mktemp)"
trap 'rm -f "$state"' EXIT
digest="$(KOGUT_STATE="$state" "$KOGUT_ROOT/scripts/collect.sh" "$repo")"

verdict="$(jq -c --arg repo "$repo" --arg path "$path" '
  .repos[] | select(.name == $repo)
  | if .error then {error: .error}
    else ([(.ci_failing + .workflows_disabled)[] | select(.path == $path)][0]
          // {error: "not a red or disabled workflow on the default branch"}) + {branch: .default_branch} end' <<<"$digest")"

error="$(jq -r '.error // empty' <<<"$verdict")"
[ -z "$error" ] || die "$repo $path: $error"
proposed="$(jq -r '.action.name // empty' <<<"$verdict")"
[ "$proposed" = "$action" ] || die "$repo $path: the rules call for ${proposed:-no action}, not $action"
id="$(jq -r '.id' <<<"$verdict")"
[[ "$id" =~ ^[0-9]+$ ]] || die "$repo $path: the snapshot has no workflow id"
run="$(jq -r '.latest_run.id // empty' <<<"$verdict")"
branch="$(jq -r '.branch' <<<"$verdict")"
name="$(jq -r '.name' <<<"$verdict")"
reason="$(jq -r '.action.reason' <<<"$verdict")"

# Checked before use: an empty GH_TOKEN would make gh act as the owner.
token="$(kogut_app_token "$repo" '{"actions":"write"}')"
[ -n "$token" ] || die "no token from the kogut App for $repo"

if [ "$dry_run" = true ]; then
  echo "would $action: $name ($path) on $repo, $reason"
  echo "not run: --dry-run (would act as $(kogut_app_bot))"
  exit 0
fi

page="https://github.com/$full/actions/workflows/${path##*/}"
case "$action" in
  rerun)
    [[ "$run" =~ ^[0-9]+$ ]] || die "$repo $path: no run to retry"
    GH_TOKEN="$token" gh api -X POST "repos/$full/actions/runs/$run/rerun-failed-jobs" --silent
    echo "retried the failed jobs of $name as $(kogut_app_bot): https://github.com/$full/actions/runs/$run"
    ;;
  dispatch)
    GH_TOKEN="$token" gh api -X POST "repos/$full/actions/workflows/$id/dispatches" -f ref="$branch" --silent
    echo "started $name on $branch as $(kogut_app_bot): $page"
    ;;
  enable)
    GH_TOKEN="$token" gh api -X PUT "repos/$full/actions/workflows/$id/enable" --silent
    echo "enabled $name as $(kogut_app_bot): $page"
    ;;
esac
