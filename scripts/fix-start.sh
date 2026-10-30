#!/usr/bin/env bash
# Starts a fix: a worktree of a watched repository at its default branch as it
# is on GitHub, where the model edits files. Nothing leaves the machine until
# scripts/open-fix-pr.sh, which the owner approves.
#
#   ./scripts/fix-start.sh <repo> <slug>             # prints the worktree path
#   ./scripts/fix-start.sh <repo> <slug> --discard   # removes the fix again
#
# The worktree is .kogut/fixes/<repo>/<slug>/, and the PR text goes next to it
# in .kogut/fixes/<repo>/<slug>.md: the title on the first line, a blank line,
# then the body. The checkout is detached and nothing is committed locally:
# open-fix-pr.sh makes the commit on GitHub, as the kogut App.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: fix-start.sh <repo> <slug> [--discard]"
[ $# -ge 2 ] && [ $# -le 3 ] || die "$usage"
repo="$1" slug="$2"
kogut_require_repo "$repo"
# The slug becomes the branch kogut/<slug>, so it stays short and plain.
[[ "$slug" =~ ^[a-z0-9][a-z0-9-]{1,48}$ ]] || die "slug must be lowercase letters, digits and dashes: $slug"
dir="$(kogut_repo_path "$repo")"
[ -d "$dir/.git" ] || die "no local clone of $repo at $dir"
worktree="$KOGUT_ROOT/.kogut/fixes/$repo/$slug"

if [ $# -eq 3 ]; then
  [ "$3" = --discard ] || die "$usage"
  [ -d "$worktree" ] || die "there is no fix $repo/$slug"
  git -C "$dir" worktree remove --force "$worktree"
  rm -f "$worktree.md"
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
