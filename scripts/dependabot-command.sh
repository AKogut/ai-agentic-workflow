#!/usr/bin/env bash
# Asks Dependabot to rebase or recreate one of its PRs, and only when the rules
# in signals.jq name that command for the PR. The state is collected afresh, so
# the decision never rests on an old snapshot, and a PR gets one command per
# head commit.
#
#   ./scripts/dependabot-command.sh <repo> <pr> <rebase|recreate> [--dry-run]
#
# This is the one write kogut makes as the owner. Dependabot takes commands only
# from users with push access and answers the App with "Sorry, only users with
# push access can use that command", so no token of the App's can do this. The
# owner approves each call, and all the script can post is the command alone,
# which is how Dependabot reads it. Dependabot acknowledges a command with a
# thumbs-up; the script waits briefly for it and says whether it came.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: dependabot-command.sh <repo> <pr> <rebase|recreate> [--dry-run]"
[ $# -ge 3 ] && [ $# -le 4 ] || die "$usage"
repo="$1" pr="$2" command="$3" dry_run=false
kogut_require_repo "$repo"
kogut_require_not_held "$repo"
[[ "$pr" =~ ^[0-9]+$ ]] || die "PR number must be numeric: $pr"
case "$command" in rebase | recreate) ;; *) die "$usage" ;; esac
if [ $# -eq 4 ]; then
  [ "$4" = --dry-run ] || die "$usage"
  dry_run=true
fi
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
proposed="$(jq -r '.command.name // empty' <<<"$verdict")"
if [ "$proposed" != "$command" ]; then
  asked="$(jq -r '.asked | if . then "kogut asked for a \(.command) at \(.at), and the head has not changed since" else empty end' <<<"$verdict")"
  note="$(jq -r '.dependabot_note | if . then "Dependabot said: \(.text)" else empty end' <<<"$verdict")"
  die "$repo #$pr: the rules call for ${proposed:-no command}, not $command${asked:+; $asked}${note:+; $note}"
fi
reason="$(jq -r '.command.reason' <<<"$verdict")"
title="$(jq -r '.title' <<<"$verdict")"

# The login in use must be the owner's: signals.jq counts only the owner's
# commands, and Dependabot obeys only someone with push access.
unset GH_TOKEN GITHUB_TOKEN
owner="$(kogut_owner)"
[ "$(gh api user --jq .login)" = "$owner" ] || die "gh is not logged in as $owner"

if [ "$dry_run" = true ]; then
  echo "would ask: @dependabot $command on $repo #$pr ($reason): $title"
  echo "not sent: --dry-run (would comment as $owner)"
  exit 0
fi

read -r id url < <(gh api -X POST "repos/$full/issues/$pr/comments" \
  -f body="@dependabot $command" --jq '"\(.id) \(.html_url)"') || true
[ -n "${id:-}" ] || die "$repo #$pr: the comment was not posted"
echo "asked: @dependabot $command on $repo #$pr as $owner ($reason): $url"

for _ in 1 2 3 4 5 6; do
  sleep 5
  seen="$(gh api "repos/$full/issues/comments/$id/reactions" \
    --jq '[.[] | select(.user.login == "dependabot[bot]" and .content == "+1")] | length')"
  if [ "$seen" -gt 0 ]; then
    echo "Dependabot acknowledged the command"
    exit 0
  fi
done
echo "no thumbs-up from Dependabot within 30 seconds: check $url"
