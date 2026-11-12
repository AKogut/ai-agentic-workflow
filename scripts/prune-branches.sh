#!/usr/bin/env bash
# Deletes branches whose work is already merged, as the kogut App, and only the
# ones the rules in signals.jq call prunable. The state is collected afresh, so
# the decision never rests on an old snapshot.
#
#   ./scripts/prune-branches.sh <repo> --dry-run                 # the candidates and what stays
#   ./scripts/prune-branches.sh <repo> [--dry-run] <branch> ...  # these branches
#
# The names go in the call, so the owner reads them in the permission prompt:
# one approval for a named list. A name the rules do not call prunable is
# refused, the rest go on, and the script fails at the end, naming what it left.
# A deleted branch is printed with its tip and its PR, whose "Restore branch"
# button brings it back. The App's token for this carries contents: write and
# nothing else.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: prune-branches.sh <repo> --dry-run | <repo> [--dry-run] <branch> [<branch> ...]"
[ $# -ge 2 ] || die "$usage"
repo="$1"
shift
kogut_require_repo "$repo"
kogut_require_not_held "$repo"
dry_run=false
names=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=true ;;
    *) names+=("$arg") ;;
  esac
done
[ "${#names[@]}" -gt 0 ] || [ "$dry_run" = true ] || die "$usage"
full="$(kogut_owner)/$repo"
kogut_read_env "$repo"

# A name goes into a URL below, so only one that needs no encoding and cannot
# walk out of refs/heads/ gets that far. A real branch with an odd name is the
# owner's to delete.
safe_name() {
  local name_re='^[A-Za-z0-9][A-Za-z0-9._/-]*$'
  [[ "$1" =~ $name_re ]] || return 1
  [ "${#1}" -le 255 ] || return 1
  case "$1" in *..* | *//* | */ | */.* | *.lock | *.) return 1 ;; esac
}

# A snapshot of its own, so the run's .kogut/state.json stays as it was.
state="$(mktemp)"
trap 'rm -f "$state"' EXIT
digest="$(KOGUT_STATE="$state" "$KOGUT_ROOT/scripts/collect.sh" "$repo")"

report="$(jq -c --arg repo "$repo" '.repos[] | select(.name == $repo)' <<<"$digest")"
error="$(jq -r '.error // empty' <<<"$report")"
[ -z "$error" ] || die "$repo: $error"
[ "$(jq -r '.branches.status' <<<"$report")" = ok ] || die "$repo: the branches could not be read, so none can be judged"

if [ "${#names[@]}" -eq 0 ]; then
  jq -r '
    .branches as $b
    | "\(.name): \($b.prunable | length) prunable, \($b.kept | length) kept",
      "prunable:",
      ($b.prunable[] | "  \(.name) at \(.tip[0:7]), head of merged PR #\(.pr) into \(.merged_into)"),
      "kept:",
      ($b.kept | group_by(.kind)[] | "  \(length) \(.[0].kind):", (.[] | "    \(.name): \(.reason)"))' <<<"$report"
  exit 0
fi

# Checked before use: an empty GH_TOKEN would make gh act as the owner.
token="$(kogut_app_token "$repo" '{"contents":"write"}')"
[ -n "$token" ] || die "no token from the kogut App for $repo"

left=""
for branch in "${names[@]}"; do
  if ! safe_name "$branch"; then
    echo "kogut: $repo: not deleted, not a plain branch name: $branch" >&2
    left="$left $branch"
    continue
  fi
  entry="$(jq -c --arg b "$branch" '.branches.prunable[] | select(.name == $b)' <<<"$report")"
  if [ -z "$entry" ]; then
    why="$(jq -r --arg b "$branch" '(.branches.kept[] | select(.name == $b) | .reason) // "no such branch"' <<<"$report")"
    echo "kogut: $repo $branch: not deleted: $why" >&2
    left="$left $branch"
    continue
  fi
  tip="$(jq -r '.tip' <<<"$entry")"
  number="$(jq -r '.pr' <<<"$entry")"
  # The delete cannot be pinned to a commit, so the tip is read again just before.
  now="$(gh api "repos/$full/git/ref/heads/$branch" --jq '.object.sha' 2>/dev/null || true)"
  if [ "$now" != "$tip" ]; then
    echo "kogut: $repo $branch: not deleted: its tip moved from ${tip:0:7} to ${now:-nothing}" >&2
    left="$left $branch"
    continue
  fi
  if [ "$dry_run" = true ]; then
    echo "would delete: $repo $branch at $tip, head of merged PR #$number (as $(kogut_app_bot))"
    continue
  fi
  if GH_TOKEN="$token" gh api -X DELETE "repos/$full/git/refs/heads/$branch" --silent; then
    echo "deleted: $repo $branch at $tip as $(kogut_app_bot); restore it from https://github.com/$full/pull/$number"
  else
    echo "kogut: $repo $branch: GitHub refused the delete" >&2
    left="$left $branch"
  fi
done
[ -z "$left" ] || die "$repo: not deleted:$left"
