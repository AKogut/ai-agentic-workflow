#!/usr/bin/env bash
# Merges one Dependabot PR, and only when the gate in signals.jq says it is
# ready. The state is collected afresh, so the decision never rests on an old
# snapshot, and the merge is pinned to the commit the gate judged.
#
#   ./scripts/merge-dependabot.sh <repo> <pr> [<pr> ...] [--major] [--head <sha>] [--dry-run]
#
# A list is one approval for the PRs it names, all in one repository: the owner
# reads the numbers in the permission prompt. Each PR is still judged and merged
# on its own, from its own fresh collection, because a merge changes what the
# next PR sees. A PR that is refused stays open, the rest go on, and the script
# fails at the end, naming what it left.
#
# A major merges only with --major, which the model passes after reviewing the
# release notes, so the owner sees it in the permission prompt. That makes it a
# call of its own: --major takes one PR. --dry-run stops before the merge. The
# merge is made by the kogut App, so it shows as kogut's, and the App has no way
# past the ruleset: a PR that the ruleset blocks stays blocked. The script never
# passes --admin either. --head takes one PR, and refuses when the commit the gate
# judged is not the one the caller decided on, which is how auto-merge.sh calls it.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: merge-dependabot.sh <repo> <pr> [<pr> ...] [--major] [--head <sha>] [--dry-run]"
[ $# -ge 2 ] || die "$usage"
repo="$1"
shift
kogut_require_repo "$repo"
kogut_require_not_held "$repo"
major=false dry_run=false expected=""
prs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --major) major=true ;;
    --dry-run) dry_run=true ;;
    --head)
      [ $# -ge 2 ] && [[ "$2" =~ ^[0-9a-f]{40}$ ]] || die "--head takes a full commit id"
      expected="$2"
      shift
      ;;
    *)
      [[ "$1" =~ ^[0-9]+$ ]] || die "PR number must be numeric: $1"
      prs+=("$1")
      ;;
  esac
  shift
done
[ "${#prs[@]}" -gt 0 ] || die "$usage"

if [ "${#prs[@]}" -gt 1 ]; then
  [ "$major" = false ] || die "--major takes one PR: a major is a call of its own"
  [ -z "$expected" ] || die "--head takes one PR"
  left=""
  for n in "${prs[@]}"; do
    if [ "$dry_run" = true ]; then
      "$0" "$repo" "$n" --dry-run || left="$left #$n"
    else
      "$0" "$repo" "$n" || left="$left #$n"
    fi
  done
  [ -z "$left" ] || die "$repo: not merged:$left"
  exit 0
fi
pr="${prs[0]}"
full="$(kogut_owner)/$repo"

# A snapshot of its own, so the run's .kogut/state.json stays as it was.
state="$(mktemp)"
trap 'rm -f "$state"' EXIT

# After a merge GitHub works out mergeability again, and until it has, the other
# PRs in the repository read UNKNOWN. That alone is worth waiting for; anything
# else in the way is an answer.
for _ in 1 2 3 4 5 6; do
  digest="$(KOGUT_STATE="$state" "$KOGUT_ROOT/scripts/collect.sh" "$repo")"
  verdict="$(jq -c --arg repo "$repo" --argjson pr "$pr" '
    .repos[] | select(.name == $repo)
    | if .error then {error: .error}
      else (.dependabot_prs[] | select(.number == $pr)) // {error: "not an open Dependabot PR"} end' <<<"$digest")"
  jq -e '.blockers == ["mergeable: UNKNOWN"]' <<<"$verdict" >/dev/null || break
  sleep 10
done

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
[ -z "$expected" ] || [ "$head" = "$expected" ] ||
  die "$repo #$pr moved from ${expected:0:7} to ${head:0:7} since it was judged"
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
