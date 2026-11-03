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
#   ./scripts/run-workflow.sh <repo> <workflow file> dispatch --pr <n> [--workflows] [--dry-run]
#
# <workflow file> is the path the digest shows, .github/workflows/<name>.yml.
# The App's token for this carries actions: write and nothing else. A dispatch
# runs the default branch, with no inputs.
#
# With --pr it runs the branch of one PR instead, for a check the PR itself does
# not get, such as an E2E suite that runs only by hand. Only Dependabot's and
# kogut's own PRs qualify. Such a run has the repository's secrets, which
# Dependabot's own runs do not, so a Dependabot PR must be past its cooldown,
# and a PR that changes .github/workflows/ needs --workflows, for the owner to
# see in the prompt. It refuses while a run is going on the PR's head or after
# one has passed there, and past policy.pr_run_limit runs by the App on that
# head. Those are the rules for this; signals.jq only names the cooldown.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: run-workflow.sh <repo> <workflow file> <rerun|dispatch|enable> [--dry-run]
       run-workflow.sh <repo> <workflow file> dispatch --pr <n> [--workflows] [--dry-run]"
[ $# -ge 3 ] || die "$usage"
repo="$1" path="$2" action="$3" dry_run=false pr="" workflows=false
shift 3
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=true ;;
    --workflows) workflows=true ;;
    --pr)
      [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || die "$usage"
      pr="$2"
      shift
      ;;
    *) die "$usage" ;;
  esac
  shift
done
kogut_require_repo "$repo"
kogut_require_not_held "$repo"
[[ "$path" =~ ^\.github/workflows/[A-Za-z0-9._-]+\.ya?ml$ ]] || die "not a workflow file: $path"
case "$action" in rerun | dispatch | enable) ;; *) die "$usage" ;; esac
if [ -n "$pr" ]; then
  [ "$action" = dispatch ] || die "--pr goes with dispatch, not $action"
else
  [ "$workflows" = false ] || die "--workflows goes with --pr"
fi
full="$(kogut_owner)/$repo"

# A snapshot of its own, so the run's .kogut/state.json stays as it was.
state="$(mktemp)"
trap 'rm -f "$state"' EXIT
digest="$(KOGUT_STATE="$state" "$KOGUT_ROOT/scripts/collect.sh" "$repo")"

if [ -n "$pr" ]; then
  verdict="$(jq -c --arg repo "$repo" --argjson pr "$pr" '
    .repos[] | select(.name == $repo)
    | if .error then {error: .error}
      else ((.dependabot_prs + .kogut_prs)[] | select(.number == $pr))
        // {error: "not an open PR from Dependabot or kogut"} end' <<<"$digest")"
  error="$(jq -r '.error // empty' <<<"$verdict")"
  [ -z "$error" ] || die "$repo #$pr: $error"
  if [ "$(jq -r '.in_cooldown // false' <<<"$verdict")" = true ]; then
    die "$repo #$pr is still in its cooldown: a run on its branch has the repository's secrets"
  fi
  branch="$(jq -r '.branch' <<<"$verdict")"
  head="$(jq -r '.head' <<<"$verdict")"
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || die "$repo #$pr: the snapshot has no head commit"

  # Read first, so a failed request stops here and cannot pass for "no workflows".
  files="$(gh api --paginate "repos/$full/pulls/$pr/files?per_page=100" --jq '.[].filename')"
  if grep -q '^\.github/workflows/' <<<"$files"; then
    [ "$workflows" = true ] || die "$repo #$pr changes .github/workflows/: pass --workflows"
  else
    [ "$workflows" = false ] || die "$repo #$pr changes no workflow: drop --workflows"
  fi

  workflow="$(jq -c --arg repo "$repo" --arg path "$path" \
    '.repos[] | select(.name == $repo) | [.workflows[] | select(.path == $path)][0] // empty' "$state")"
  [ -n "$workflow" ] || die "$repo: no workflow at $path"
  [ "$(jq -r '.state' <<<"$workflow")" = active ] || die "$repo $path is not active"
  id="$(jq -r '.id' <<<"$workflow")"
  name="$(jq -r '.name' <<<"$workflow")"
  gh api -H 'Accept: application/vnd.github.raw' "repos/$full/contents/$path?ref=$branch" |
    grep -Eq '^[^#]*workflow_dispatch' || die "$repo $path cannot be started by hand on $branch"

  bot="$(kogut_app_bot)"
  runs="$(gh api "repos/$full/actions/workflows/$id/runs?head_sha=$head&per_page=100" \
    --jq '[.workflow_runs[] | {status, conclusion, by: .triggering_actor.login}]')"
  jq -e 'any(.[]; .status != "completed") | not' <<<"$runs" >/dev/null ||
    die "$repo #$pr: $name is already running on ${head:0:7}"
  jq -e 'any(.[]; .conclusion == "success") | not' <<<"$runs" >/dev/null ||
    die "$repo #$pr: $name already passed on ${head:0:7}"
  limit="$(kogut_policy pr_run_limit)"
  jq -e --arg bot "$bot" --argjson limit "$limit" '[.[] | select(.by == $bot)] | length < $limit' <<<"$runs" >/dev/null ||
    die "$repo #$pr: $bot already ran $name $limit times on ${head:0:7}, so this is the owner's call"

  # Checked before use: an empty GH_TOKEN would make gh act as the owner.
  token="$(kogut_app_token "$repo" '{"actions":"write"}')"
  [ -n "$token" ] || die "no token from the kogut App for $repo"

  if [ "$dry_run" = true ]; then
    echo "would dispatch: $name ($path) on $repo #$pr, branch $branch at ${head:0:7}"
    echo "not run: --dry-run (would act as $bot)"
    exit 0
  fi

  GH_TOKEN="$token" gh api -X POST "repos/$full/actions/workflows/$id/dispatches" -f ref="$branch" --silent
  echo "started $name on $repo #$pr, branch $branch at ${head:0:7}, as $bot: https://github.com/$full/actions/workflows/${path##*/}"
  exit 0
fi

verdict="$(jq -c --arg repo "$repo" --arg path "$path" '
  .repos[] | select(.name == $repo)
  | if .error then {error: .error}
    else ([(.ci_failing + .workflows_disabled)[] | select(.path == $path)][0]
          // {error: "not a red or disabled workflow on the default branch"}) + {branch: .default_branch} end' <<<"$digest")"

error="$(jq -r '.error // empty' <<<"$verdict")"
[ -z "$error" ] || die "$repo $path: $error"
proposed="$(jq -r '.action.name // empty' <<<"$verdict")"
held="$(jq -r '.held // empty' <<<"$verdict")"
[ "$proposed" = "$action" ] || die "$repo $path: the rules call for ${proposed:-no action}, not $action${held:+: $held}"
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
