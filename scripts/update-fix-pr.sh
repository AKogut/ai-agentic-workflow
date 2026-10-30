#!/usr/bin/env bash
# Pushes a follow-up commit to one of kogut's own open PRs, as the kogut App,
# and says on the PR what changed and why. It is for a PR whose checks are red
# or whose review asked for changes. Start the worktree with
# `fix-start.sh <repo> --pr <number>`.
#
#   ./scripts/update-fix-pr.sh <repo> <slug> [--workflows] [--dry-run]
#   ./scripts/update-fix-pr.sh <repo> <slug> --comment-only [--dry-run]
#
# .kogut/fixes/<repo>/<slug>.md holds the commit message on its first line
# and, after a blank line, the comment for the PR. The commit goes on top of
# the head the worktree started from, and the branch moves only as a fast
# forward from that head, so nothing anyone pushed meanwhile is overwritten.
# After policy.followup_limit follow-up commits the script refuses: the owner
# takes over.
#
# With --comment-only the whole file is the comment and nothing is committed:
# the answer to a question, or to a request that needs no change. A comment is
# not an attempt. The owner approves each call, so run it with --dry-run first.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: update-fix-pr.sh <repo> <slug> [--workflows | --comment-only] [--dry-run]"
[ $# -ge 2 ] || die "$usage"
repo="$1" slug="$2"
shift 2
kogut_require_repo "$repo"
[[ "$slug" =~ ^[a-z0-9][a-z0-9-]{1,48}$ ]] || die "not a fix slug: $slug"
workflows=false dry_run=false comment_only=false
for arg in "$@"; do
  case "$arg" in
    --workflows) workflows=true ;;
    --comment-only) comment_only=true ;;
    --dry-run) dry_run=true ;;
    *) die "$usage" ;;
  esac
done
worktree="$KOGUT_ROOT/.kogut/fixes/$repo/$slug"
text="$worktree.md"
marker="$worktree.pr"
[ -d "$worktree" ] || die "there is no fix $repo/$slug"
[ -f "$marker" ] || die "fix $repo/$slug does not follow up a PR: start it with fix-start.sh $repo --pr <number>"
number="$(jq -r '.number' "$marker")"
head="$(jq -r '.head' "$marker")"
[ "$(git -C "$worktree" rev-parse HEAD)" = "$head" ] || die "the worktree is no longer at the head it started from"

if [ "$comment_only" = true ]; then
  [ "$workflows" = false ] || die "$usage"
  [ -s "$text" ] || die "the comment is missing: $text"
  git -C "$worktree" add -A
  git -C "$worktree" diff --cached --quiet HEAD || die "the worktree has changes: push them without --comment-only"
  kogut_scan <"$text" || die "gitleaks flagged the comment; nothing was sent"
  comment="$(cat "$text")"
else
  title="$(kogut_fix_title "$text")"
  comment="$(tail -n +3 "$text")"
  kogut_stage "$worktree" "$workflows" "$text"
fi

full="$(kogut_owner)/$repo"
branch="kogut/$slug"
limit="$(kogut_policy followup_limit)"
pr="$(gh pr view "$number" -R "$full" --json state,author,headRefName,headRefOid,url,commits)"
[ "$(jq -r '.state' <<<"$pr")" = OPEN ] || die "#$number is not open"
[ "$(jq -r '.author.login' <<<"$pr")" = "app/$(kogut_app_slug)" ] || die "#$number is not kogut's PR"
[ "$(jq -r '.headRefName' <<<"$pr")" = "$branch" ] || die "#$number is not on $branch"
[ "$(jq -r '.headRefOid' <<<"$pr")" = "$head" ] || die "#$number moved since the worktree started; start again"
# The PR's first commit opened it; every later one of kogut's is an attempt.
attempts="$(jq --arg bot "$(kogut_app_bot)" '[.commits[] | select(any(.authors[]; .login == $bot))] | length - 1' <<<"$pr")"
attempt=$((attempts + 1))
if [ "$comment_only" = false ]; then
  [ "$attempts" -lt "$limit" ] || die "#$number already has $attempts follow-up commits (limit $limit): the owner takes over"
fi

if [ "$dry_run" = true ] && [ "$comment_only" = true ]; then
  echo "comment on $(jq -r '.url' <<<"$pr"), as $(kogut_app_bot), no commit"
  echo "--- comment"
  printf '%s\n' "$comment"
  echo "not sent: --dry-run"
  exit 0
fi
if [ "$dry_run" = true ]; then
  echo "follow-up $attempt of $limit on $(jq -r '.url' <<<"$pr"), as $(kogut_app_bot)"
  echo "commit: $title"
  echo "--- files"
  kogut_show_diff "$worktree"
  echo "--- comment"
  printf '%s\n' "$comment"
  echo "not pushed: --dry-run"
  exit 0
fi

# From here on every call is the App's. The check matters: an empty GH_TOKEN
# would make gh fall back to the owner's login.
token="$(kogut_app_token "$repo")"
[ -n "$token" ] || die "no token from the kogut App for $repo"
export GH_TOKEN="$token"

if [ "$comment_only" = true ]; then
  note="kogut answered without a change."
else
  commit="$(kogut_api_commit "$full" "$worktree" "$title")"
  gh api -X PATCH "repos/$full/git/refs/heads/$branch" -f sha="$commit" -F force=false >/dev/null
  note="kogut pushed ${commit:0:7} to this PR (follow-up $attempt of $limit)."
fi
jq -n --arg c "$comment" --arg note "$note" '{body: "\($c)\n\n<sub>\($note)</sub>"}' |
  gh api -X POST "repos/$full/issues/$number/comments" --input - >/dev/null

git -C "$(kogut_repo_path "$repo")" worktree remove --force "$worktree"
mkdir -p "$KOGUT_ROOT/.kogut/sent"
stamp="$(date +%Y%m%d-%H%M%S)"
mv "$text" "$KOGUT_ROOT/.kogut/sent/$stamp-followup-$repo-$slug.md"
rm -f "$marker"
if [ "$comment_only" = true ]; then
  echo "answered: $(jq -r '.url' <<<"$pr") (a comment, as $(kogut_app_bot))"
else
  echo "pushed: ${commit:0:7} to $(jq -r '.url' <<<"$pr") (follow-up $attempt of $limit, as $(kogut_app_bot))"
fi
