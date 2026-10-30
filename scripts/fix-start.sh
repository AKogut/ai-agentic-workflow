#!/usr/bin/env bash
# Starts a fix: a worktree of a watched repository where the model edits files.
# Nothing leaves the machine until open-fix-pr.sh or update-fix-pr.sh, which
# the owner approves.
#
#   ./scripts/fix-start.sh <repo> <slug>             # a new fix, at the default branch
#   ./scripts/fix-start.sh <repo> --pr <number>      # a follow-up to one of kogut's PRs
#   ./scripts/fix-start.sh <repo> <slug> --discard   # removes the fix again
#
# A new fix starts from the default branch as it is on GitHub. A follow-up
# starts from the head of kogut's open PR, and its slug is the PR's branch
# kogut/<slug>. The worktree is .kogut/fixes/<repo>/<slug>/, and the text goes
# next to it in .kogut/fixes/<repo>/<slug>.md: the title on the first line, a
# blank line, then the body (for a follow-up: the commit message, then the
# comment for the PR). The checkout is detached and nothing is committed
# locally: the commit is made on GitHub, as the kogut App.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: fix-start.sh <repo> <slug> [--discard] | fix-start.sh <repo> --pr <number>"
[ $# -ge 2 ] && [ $# -le 3 ] || die "$usage"
repo="$1"
kogut_require_repo "$repo"
dir="$(kogut_repo_path "$repo")"
[ -d "$dir/.git" ] || die "no local clone of $repo at $dir"
slug_re='^[a-z0-9][a-z0-9-]{1,48}$'

if [ "$2" = --pr ]; then
  [ $# -eq 3 ] || die "$usage"
  number="$3"
  [[ "$number" =~ ^[0-9]+$ ]] || die "PR number must be numeric: $number"
  pr="$(gh pr view "$number" -R "$(kogut_owner)/$repo" --json state,author,headRefName,headRefOid)"
  [ "$(jq -r '.state' <<<"$pr")" = OPEN ] || die "#$number is not open"
  [ "$(jq -r '.author.login' <<<"$pr")" = "app/$(kogut_app_slug)" ] || die "#$number is not kogut's PR"
  branch="$(jq -r '.headRefName' <<<"$pr")"
  head="$(jq -r '.headRefOid' <<<"$pr")"
  slug="${branch#kogut/}"
  [ "$branch" = "kogut/$slug" ] && [[ "$slug" =~ $slug_re ]] || die "#$number is on $branch, not on a kogut/<slug> branch"
  worktree="$KOGUT_ROOT/.kogut/fixes/$repo/$slug"
  [ ! -e "$worktree" ] || die "fix $repo/$slug already exists at $worktree; open it or discard it"
  git -C "$dir" fetch --quiet origin "refs/pull/$number/head"
  [ "$(git -C "$dir" rev-parse FETCH_HEAD)" = "$head" ] || die "#$number moved while it was fetched; start again"
  mkdir -p "$(dirname "$worktree")"
  git -C "$dir" worktree add --quiet --detach "$worktree" "$head"
  # update-fix-pr.sh reads this to push on top of exactly this head.
  jq -n --argjson n "$number" --arg h "$head" '{number: $n, head: $h}' >"$worktree.pr"
  echo "worktree: $worktree"
  echo "follows up: #$number at ${head:0:7}, branch $branch"
  echo "text: $worktree.md (the commit message, a blank line, then the comment for the PR)"
  exit 0
fi

slug="$2"
# The slug becomes the branch kogut/<slug>, so it stays short and plain.
[[ "$slug" =~ $slug_re ]] || die "slug must be lowercase letters, digits and dashes: $slug"
worktree="$KOGUT_ROOT/.kogut/fixes/$repo/$slug"

if [ $# -eq 3 ]; then
  [ "$3" = --discard ] || die "$usage"
  [ -d "$worktree" ] || die "there is no fix $repo/$slug"
  git -C "$dir" worktree remove --force "$worktree"
  rm -f "$worktree.md" "$worktree.pr"
  echo "discarded: $repo/$slug"
  exit 0
fi

[ ! -e "$worktree" ] || die "fix $repo/$slug already exists at $worktree; open it or discard it"
branch="$(kogut_default_branch "$repo")"
git -C "$dir" fetch --quiet origin "$branch"
mkdir -p "$(dirname "$worktree")"
git -C "$dir" worktree add --quiet --detach "$worktree" "origin/$branch"
echo "worktree: $worktree"
echo "base: $branch at $(git -C "$worktree" rev-parse --short HEAD)"
echo "PR text: $worktree.md (title, a blank line, then the body)"
