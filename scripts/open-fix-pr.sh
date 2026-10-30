#!/usr/bin/env bash
# Opens a fix started with fix-start.sh as a PR from the kogut App. The commit
# and the PR show as <slug>[bot], and the owner reviews and merges on GitHub.
#
#   ./scripts/open-fix-pr.sh <repo> <slug> [--workflows] [--dry-run]
#
# The owner approves each call, so run it with --dry-run first: that prints the
# PR text and the diff, and stops. A fix that changes .github/workflows/ needs
# --workflows: a workflow on the PR branch runs with the repository's secrets
# before anyone reviews it, and the owner should see that in the prompt.
#
# Before anything leaves the machine, the changed lines and the PR text are
# scanned with gitleaks. The commit is built through GitHub's Git database API
# from the blobs and modes git staged, and GitHub's tree must hash to the
# staged tree before the branch is created, so the PR holds exactly the diff
# that was shown.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: open-fix-pr.sh <repo> <slug> [--workflows] [--dry-run]"
[ $# -ge 2 ] || die "$usage"
repo="$1" slug="$2"
shift 2
kogut_require_repo "$repo"
[[ "$slug" =~ ^[a-z0-9][a-z0-9-]{1,48}$ ]] || die "not a fix slug: $slug"
workflows=false dry_run=false
for arg in "$@"; do
  case "$arg" in
    --workflows) workflows=true ;;
    --dry-run) dry_run=true ;;
    *) die "$usage" ;;
  esac
done
worktree="$KOGUT_ROOT/.kogut/fixes/$repo/$slug"
text="$worktree.md"
[ -d "$worktree" ] || die "there is no fix $repo/$slug: start it with fix-start.sh"
title="$(kogut_fix_title "$text")"
body="$(tail -n +3 "$text")"
kogut_stage "$worktree" "$workflows" "$text"

full="$(kogut_owner)/$repo"
base_branch="$(kogut_default_branch "$repo")"
base="$(git -C "$worktree" rev-parse HEAD)"
branch="kogut/$slug"

if [ "$dry_run" = true ]; then
  echo "PR: $title"
  echo "into: $full $base_branch at ${base:0:7}, from $branch, as $(kogut_app_bot)"
  echo "--- files"
  kogut_show_diff "$worktree"
  echo "--- body"
  printf '%s\n' "$body"
  echo "not opened: --dry-run"
  exit 0
fi

# From here on every call is the App's. The check matters: an empty GH_TOKEN
# would make gh fall back to the owner's login.
token="$(kogut_app_token "$repo")"
[ -n "$token" ] || die "no token from the kogut App for $repo"
export GH_TOKEN="$token"

! gh api "repos/$full/git/ref/heads/$branch" >/dev/null 2>&1 || die "branch $branch already exists on $full"

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT
commit="$(kogut_api_commit "$full" "$worktree" "$title")"
gh api -X POST "repos/$full/git/refs" -f ref="refs/heads/$branch" -f sha="$commit" >/dev/null

{
  printf '%s\n\n---\n' "$body"
  printf '<sub>Opened by [kogut](%s), the maintenance agent for this portfolio. %s reviews and merges.</sub>\n' \
    "$(jq -r '.app.homepage' "$KOGUT_CONFIG")" "$(kogut_owner)"
} >"$body_file"
if ! url="$(gh pr create -R "$full" --base "$base_branch" --head "$branch" --title "$title" --body-file "$body_file")"; then
  gh api -X DELETE "repos/$full/git/refs/heads/$branch" >/dev/null 2>&1 || true
  die "could not open the PR; the branch $branch was deleted again"
fi

git -C "$(kogut_repo_path "$repo")" worktree remove --force "$worktree"
mkdir -p "$KOGUT_ROOT/.kogut/sent"
mv "$text" "$KOGUT_ROOT/.kogut/sent/$(date +%Y%m%d-%H%M%S)-fix-$repo-$slug.md"
echo "opened: $url (as $(kogut_app_bot), branch $branch)"
