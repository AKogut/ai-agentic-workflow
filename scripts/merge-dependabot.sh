#!/usr/bin/env bash
# Merges one Dependabot PR, and only when the gate in signals.jq says it is
# ready. The state is collected afresh, so the decision never rests on an old
# snapshot, and the merge is pinned to the commit the gate judged.
#
#   ./scripts/merge-dependabot.sh <repo> <pr> [--major] [--dry-run]
#
# A major merges only with --major, which the model passes after reviewing the
# release notes, so the owner sees it in the permission prompt. --dry-run stops
# before the merge. The merge is made by the kogut App, so it shows as kogut's,
# and the App has no way past the ruleset: a PR that the ruleset blocks stays
# blocked. The script never passes --admin either.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: merge-dependabot.sh <repo> <pr> [--major] [--dry-run]"
[ $# -ge 2 ] || die "$usage"
repo="$1" pr="$2"
shift 2
kogut_require_repo "$repo"
[[ "$pr" =~ ^[0-9]+$ ]] || die "PR number must be numeric: $pr"
major=false dry_run=false
for arg in "$@"; do
  case "$arg" in
    --major) major=true ;;
    --dry-run) dry_run=true ;;
    *) die "$usage" ;;
  esac
done
full="$(kogut_owner)/$repo"

# A snapshot of its own, so the run's .kogut/state.json stays as it was.
state="$(mktemp)"
trap 'rm -f "$state"' EXIT
digest="$(KOGUT_STATE="$state" "$KOGUT_ROOT/scripts/collect.sh" "$repo")"

verdict="$(jq -c --arg repo "$repo" --argjson pr "$pr" '
  .repos[] | select(.name == $repo)
  | if .error then {error: .error}
    else (.dependabot_prs[] | select(.number == $pr)) // {error: "not an open Dependabot PR"} end' <<<"$digest")"

error="$(jq -r '.error // empty' <<<"$verdict")"
[ -z "$error" ] || die "$repo #$pr: $error"
[ "$(jq -r '.ready_to_merge' <<<"$verdict")" = true ] ||
  die "$repo #$pr is not ready: $(jq -r '.blockers | join("; ")' <<<"$verdict")"

semver="$(jq -r '.semver' <<<"$verdict")"
if [ "$semver" = major ] && [ "$major" != true ]; then
  die "$repo #$pr is a major: review its release notes, then pass --major"
fi
if [ "$semver" != major ] && [ "$major" = true ]; then
  die "$repo #$pr is a $semver, not a major: drop --major"
fi

head="$(jq -r '.head' <<<"$verdict")"
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || die "$repo #$pr: the snapshot has no head commit"
title="$(jq -r '.title' <<<"$verdict")"

# Checked before the merge: an empty GH_TOKEN would make gh fall back to the
# owner's login, which carries the admin bypass.
token="$(kogut_app_token "$repo")"
[ -n "$token" ] || die "no token from the kogut App for $repo"

if [ "$dry_run" = true ]; then
  echo "ready: $repo #$pr ($semver) at ${head:0:7}: $title"
  echo "not merged: --dry-run (would merge as $(kogut_app_bot))"
  exit 0
fi

GH_TOKEN="$token" gh pr merge "$pr" -R "$full" --squash --match-head-commit "$head"
echo "merged: $repo #$pr ($semver) at ${head:0:7} as $(kogut_app_bot): $title"
