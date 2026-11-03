#!/usr/bin/env bash
# Dismisses every open Dependabot alert of one package in one manifest, as the
# kogut App, with the reason and the comment on record. A dismissal is the
# owner's decision: this runs only when the owner named the package and asked,
# never on its own in a sweep, and the owner approves the call. It can be
# reopened on the alert's page, and the alert then counts again.
#
#   ./scripts/dismiss-alert.sh <repo> <package> <manifest> --reason <r> --comment <text> [--severe] [--dry-run]
#
# <manifest> is the alert's path, such as app/package-lock.json. The state is
# collected afresh, and dismiss.jq decides: a critical alert is never dismissed,
# a high one needs --severe, and a package an open Dependabot PR fixes stays
# open. --dry-run prints the plan, says whether the App has the permission, and
# stops. The App's token for this carries vulnerability_alerts: write and nothing
# else, and the comment is scanned with gitleaks before anything is sent.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: dismiss-alert.sh <repo> <package> <manifest> --reason <r> --comment <text> [--severe] [--dry-run]"
[ $# -ge 3 ] || die "$usage"
repo="$1" package="$2" manifest="$3"
shift 3
reason="" comment="" severe=false dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --reason | --comment)
      [ $# -ge 2 ] || die "$usage"
      if [ "$1" = --reason ]; then reason="$2"; else comment="$2"; fi
      shift
      ;;
    --severe) severe=true ;;
    --dry-run) dry_run=true ;;
    *) die "$usage" ;;
  esac
  shift
done
kogut_require_repo "$repo"
full="$(kogut_owner)/$repo"
permission='{"vulnerability_alerts":"write"}'

# A snapshot of its own, so the run's .kogut/state.json stays as it was. The raw
# snapshot has each alert's manifest, and the digest has what each PR fixes.
state="$(mktemp)"
trap 'rm -f "$state"' EXIT
digest="$(KOGUT_STATE="$state" "$KOGUT_ROOT/scripts/collect.sh" "$repo")"

verdict="$(jq -cs --arg repo "$repo" '
  (.[0].repos[] | select(.name == $repo)) as $raw
  | (.[1].repos[] | select(.name == $repo)) as $signals
  | {error: ($raw.error // $signals.error), alerts: $raw.alerts, dependabot_prs: $signals.dependabot_prs}' "$state" - <<<"$digest" |
  jq -c --arg package "$package" --arg manifest "$manifest" --arg reason "$reason" --arg comment "$comment" \
    --argjson severe "$severe" -f "$KOGUT_ROOT/scripts/dismiss.jq")"

refusal="$(jq -r '.refusal // empty' <<<"$verdict")"
[ -z "$refusal" ] || die "$repo: $refusal"

printf '%s\n' "$comment" | kogut_scan || die "gitleaks flagged the comment; nothing was sent"

bot="$(kogut_app_bot)"
if [ "$dry_run" = true ]; then
  jq -r --arg p "$package" --arg m "$manifest" '.alerts[] | "would dismiss: #\(.number) \(.severity) \($p) in \($m): \(.url)"' <<<"$verdict"
  echo "would record: $reason: $comment"
  if token="$(kogut_app_token "$repo" "$permission" 2>/dev/null)" && [ -n "$token" ]; then
    echo "not sent: --dry-run (would act as $bot)"
  else
    echo "not sent: --dry-run. The real call would stop here too: the App got no token with vulnerability_alerts: write, so the owner has to grant it (./scripts/app.sh check)"
  fi
  exit 0
fi

# Checked before use: an empty GH_TOKEN would make gh act as the owner.
token="$(kogut_app_token "$repo" "$permission")"
[ -n "$token" ] || die "no token from the kogut App for $repo"

left=""
while IFS=$'\t' read -r number severity url; do
  [[ "$number" =~ ^[0-9]+$ ]] || die "$repo: the snapshot has an alert without a number"
  if result="$(GH_TOKEN="$token" gh api -X PATCH "repos/$full/dependabot/alerts/$number" \
    -f state=dismissed -f dismissed_reason="$reason" -f dismissed_comment="$comment" --jq .state)" &&
    [ "$result" = dismissed ]; then
    echo "dismissed: #$number $severity $package in $manifest as $bot ($reason): $url"
  else
    left="$left #$number"
  fi
done < <(jq -r '.alerts[] | [.number, .severity, .url] | @tsv' <<<"$verdict")
[ -z "$left" ] || die "$repo: not dismissed:$left"
echo "it can be reopened on the alert's page, and the alert then counts again"
