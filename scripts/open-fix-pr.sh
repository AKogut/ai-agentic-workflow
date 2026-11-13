#!/usr/bin/env bash
# Opens a fix started with fix-start.sh as a PR from the kogut App. The commit
# and the PR show as <slug>[bot], and the owner reviews and merges on GitHub.
#
#   ./scripts/open-fix-pr.sh <repo> <slug> [--workflows] [--task <issue>] [--dry-run]
#   ./scripts/open-fix-pr.sh <repo> <slug> --feature <issue> [--dry-run]
#
# --feature opens a feature the owner approved: feature.jq, asked on GitHub now,
# must say the owner approved the latest plan. Only this path allows a feat title.
# The PR is a draft, because CI is all that has run its code, and it stays within
# policy.feature's size limits. A feature never changes .github/workflows/: a
# workflow on the branch would run with the repository's secrets before review,
# and the plan is not the place to approve that.
#
# --task links the PR to a task the owner handed kogut (an issue the owner
# labelled kogut-task, which is checked on GitHub first) and says so on the
# issue. The PR closes the task when it merges, unless the issue is one kogut
# files for a finding, which closes on its own once the finding is gone.
#
# The owner approves each call, so run it with --dry-run first: that prints the
# PR text and the diff, and stops. A fix that changes .github/workflows/ needs
# --workflows: a workflow on the PR branch runs with the repository's secrets
# before anyone reviews it, and the owner should see that in the prompt. A fix
# that changes a .claude/settings.json is refused, in kogut's own repository as in
# any other: what an agent may run without asking is the owner's to set, by hand.
#
# Before anything leaves the machine, the changed lines and the PR text are
# scanned with gitleaks. The commit is built through GitHub's Git database API
# from the blobs and modes git staged, and GitHub's tree must hash to the
# staged tree before the branch is created, so the PR holds exactly the diff
# that was shown.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: open-fix-pr.sh <repo> <slug> [--workflows] [--task <issue> | --feature <issue>] [--dry-run]"
[ $# -ge 2 ] || die "$usage"
repo="$1" slug="$2"
shift 2
kogut_require_repo "$repo"
kogut_require_not_held "$repo"
[[ "$slug" =~ ^[a-z0-9][a-z0-9-]{1,48}$ ]] || die "not a fix slug: $slug"
workflows=false dry_run=false task="" feature=""
while [ $# -gt 0 ]; do
  case "$1" in
    --workflows) workflows=true ;;
    --dry-run) dry_run=true ;;
    --task)
      [ $# -ge 2 ] || die "$usage"
      task="$2"
      shift
      ;;
    --feature)
      [ $# -ge 2 ] || die "$usage"
      feature="$2"
      shift
      ;;
    *) die "$usage" ;;
  esac
  shift
done
[ -z "$task" ] || [[ "$task" =~ ^[0-9]+$ ]] || die "a task is an issue number: $task"
[ -z "$feature" ] || [[ "$feature" =~ ^[0-9]+$ ]] || die "a feature is an issue number: $feature"
[ -z "$task" ] || [ -z "$feature" ] || die "$usage"
[ -z "$feature" ] || [ "$workflows" = false ] || die "a feature cannot change .github/workflows/: that stays the owner's"
worktree="$KOGUT_ROOT/.kogut/fixes/$repo/$slug"
text="$worktree.md"
[ -d "$worktree" ] || die "there is no fix $repo/$slug: start it with fix-start.sh"
title="$(kogut_fix_title "$text" "${feature:+feature}")"
body="$(tail -n +3 "$text")"
kogut_stage "$worktree" "$workflows" "$text"
[ -z "$feature" ] || kogut_feature_size "$worktree"

full="$(kogut_owner)/$repo"
base_branch="$(kogut_default_branch "$repo")"
base="$(git -C "$worktree" rev-parse HEAD)"
branch="kogut/$slug"
link=""
if [ -n "$task" ]; then
  # Assigned first: inside [ "$(…)" = … ] a refused check would not stop the script.
  kind="$(kogut_task_check "$full" "$task")"
  if [ "$kind" = finding ]; then link="Refs #$task"; else link="Closes #$task"; fi
fi
if [ -n "$feature" ]; then
  # Assigned first: inside [ "$(…)" = … ] a refused check would not stop the script.
  stands="$(kogut_feature_state "$full" "$repo" "$feature")"
  [ "$stands" = build ] || die "#$feature is not approved to build: it says $stands"
  link="Closes #$feature"
fi

if [ "$dry_run" = true ]; then
  echo "PR: $title"
  [ -z "$link" ] || echo "task: $link"
  [ -z "$feature" ] || echo "as a draft: CI is all that has run this code"
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
  printf '%s\n\n' "$body"
  [ -z "$link" ] || printf '%s\n\n' "$link"
  printf -- '---\n'
  printf '<sub>Opened by [kogut](%s), the maintenance agent for this portfolio. %s reviews and merges.</sub>\n' \
    "$(jq -r '.app.homepage' "$KOGUT_CONFIG")" "$(kogut_owner)"
  # update-fix-pr.sh and signals.jq read this to give the PR a feature's limit.
  [ -z "$feature" ] || printf '<!-- kogut-feature: %s -->\n' "$feature"
} >"$body_file"
draft=()
[ -z "$feature" ] || draft=(--draft)
if ! url="$(gh pr create -R "$full" --base "$base_branch" --head "$branch" --title "$title" --body-file "$body_file" ${draft[@]+"${draft[@]}"})"; then
  gh api -X DELETE "repos/$full/git/refs/heads/$branch" >/dev/null 2>&1 || true
  die "could not open the PR; the branch $branch was deleted again"
fi

if [ -n "$task" ]; then
  gh api -X POST "repos/$full/issues/$task/comments" -f body="kogut opened $url for this task." >/dev/null
fi
if [ -n "$feature" ]; then
  gh api -X POST "repos/$full/issues/$feature/comments" -f body="kogut opened $url as a draft for this feature." >/dev/null
fi

git -C "$(kogut_repo_path "$repo")" worktree remove --force "$worktree"
mkdir -p "$KOGUT_ROOT/.kogut/sent"
mv "$text" "$KOGUT_ROOT/.kogut/sent/$(date +%Y%m%d-%H%M%S)-fix-$repo-$slug.md"
echo "opened: $url (as $(kogut_app_bot), branch $branch)"
