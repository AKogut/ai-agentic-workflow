#!/usr/bin/env bash
# Posts a report to the Discord channel of one watched repository, or the daily
# summary to the summary channel.
#
#   ./scripts/notify.sh <repo> <red|yellow|green>      # sends .kogut/outbox/<repo>.md
#   ./scripts/notify.sh --summary <red|yellow|green>   # sends .kogut/outbox/summary.md
#   ./scripts/notify.sh --check                        # checks every webhook, posts nothing
#   ./scripts/notify.sh --channels                     # names the repositories with a webhook
#
# Webhook URLs come from .env (DISCORD_WEBHOOK_<REPO_IN_UPPER_SNAKE_CASE>, and
# DISCORD_WEBHOOK_SUMMARY for the summary) and are never printed. The summary
# channel is optional: without its webhook the summary is skipped with one line,
# which is not a failure. Mentions are switched off, so text quoted from a PR
# cannot ping anyone. A sent report is moved to .kogut/sent/. digest.sh sets
# KOGUT_OUTBOX to send from an outbox of its own. A repository whose webhook is
# not set has no channel yet: --check shows it without failing, and --channels
# leaves it out, so digest.sh can skip it and say so. A webhook that is set but
# wrong still fails.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

env_file="$KOGUT_ROOT/.env"
[ -f "$env_file" ] || die "missing .env with the Discord webhooks (see .env.example)"
command -v curl >/dev/null || die "curl is not installed"

# The variable that holds a channel's webhook: the repository's name in upper
# snake case, or SUMMARY for the summary channel.
webhook_key() { printf 'DISCORD_WEBHOOK_%s' "$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"; }

# Reads a channel's webhook from .env without sourcing it (that would run
# whatever the file contains). Prints nothing when it is not set.
webhook_value() {
  grep -E "^$(webhook_key "$1")=" "$env_file" | tail -n 1 | cut -d= -f2- | tr -d "\"' " || true
}

# A channel's webhook. Refuses one that is not set or is not a Discord webhook.
webhook_for() {
  local key url
  key="$(webhook_key "$1")"
  url="$(webhook_value "$1")"
  [ -n "$url" ] || die "$key is not set in .env"
  [[ "$url" =~ ^https://(discord|discordapp)\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$ ]] ||
    die "$key in .env is not a Discord webhook URL"
  printf '%s' "$url"
}

resp="$(mktemp)"
trap 'rm -f "$resp"' EXIT

if [ "${1:-}" = "--channels" ]; then
  while IFS= read -r repo; do
    [ -z "$(webhook_value "$repo")" ] || echo "$repo"
  done < <(kogut_repos)
  exit 0
fi

if [ "${1:-}" = "--check" ]; then
  failed=0
  while IFS= read -r repo; do
    if [ -z "$(webhook_value "$repo")" ]; then
      echo "none  $repo → no channel yet: $(webhook_key "$repo") is not set in .env"
      continue
    fi
    if ! url="$(webhook_for "$repo")"; then
      failed=1
      continue
    fi
    code="$(curl -sS -o "$resp" -w '%{http_code}' "$url")"
    if [ "$code" = 200 ]; then
      echo "ok    $repo → channel $(jq -r .channel_id "$resp")"
    else
      echo "FAIL  $repo → HTTP $code"
      failed=1
    fi
  done < <(
    kogut_repos
    # The summary channel is optional, so its webhook is checked only when set.
    [ -z "$(webhook_value summary)" ] || echo summary
  )
  [ -n "$(webhook_value summary)" ] ||
    echo "skip  summary → $(webhook_key summary) is not set, so no summary is posted"
  exit "$failed"
fi

[ $# -eq 2 ] || die "usage: notify.sh <repo> <red|yellow|green> | --summary <red|yellow|green> | --check | --channels"
# For the summary, "repo" names the summary channel and its outbox file.
repo="$1" status="$2" summary=false
if [ "$repo" = --summary ]; then
  repo=summary summary=true title="All repositories" link="https://github.com/$(kogut_owner)"
else
  kogut_require_repo "$repo"
  title="$repo" link="https://github.com/$(kogut_owner)/$repo"
fi
case "$status" in
  red) color=15158332 emoji="🔴" ;;
  yellow) color=15844367 emoji="🟡" ;;
  green) color=3066993 emoji="🟢" ;;
  *) die "status must be red, yellow or green: $status" ;;
esac
if [ "$summary" = true ] && [ -z "$(webhook_value summary)" ]; then
  echo "summary not sent: $(webhook_key summary) is not set in .env"
  exit 0
fi
file="${KOGUT_OUTBOX:-$KOGUT_ROOT/.kogut/outbox}/$repo.md"
[ -s "$file" ] || die "nothing to send: $file is missing or empty"
url="$(webhook_for "$repo")"

# One embed per message, each under Discord's 4096-character description limit.
# A long report is split on line boundaries; only the first part has a title.
payloads="$(jq -Rs -c \
  --arg title "$emoji $title" \
  --arg link "$link" \
  --argjson color "$color" \
  --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  def pieces($max): if length <= $max then . else range(0; length; $max) as $o | .[$o:$o + $max] end;
  [split("\n")[] | pieces(3800)]
  | reduce .[] as $line ([""];
      (length - 1) as $i
      | if (.[$i] | length) == 0 then .[$i] = $line
        elif (.[$i] | length) + ($line | length) + 1 > 3800 then . + [$line]
        else .[$i] += "\n" + $line end)
  | map(select(test("\\S")))
  | length as $n
  | to_entries[]
  | {
      username: "kogut",
      allowed_mentions: {parse: []},
      embeds: [
        {description: .value, color: $color, timestamp: $now}
        + (if .key == 0 then {title: $title, url: $link} else {} end)
        + (if $n > 1 then {footer: {text: "\(.key + 1)/\($n)"}} else {} end)
      ]
    }' "$file")"

sent=0
while IFS= read -r payload; do
  for _ in 1 2 3; do
    code="$(curl -sS -o "$resp" -w '%{http_code}' -H 'Content-Type: application/json' \
      --data-binary "$payload" "$url?wait=true")"
    case "$code" in
      2??) break ;;
      429) sleep "$(jq -r '.retry_after // 1 | ceil' "$resp")" ;;
      *) die "Discord answered HTTP $code for $repo: $(head -c 300 "$resp")" ;;
    esac
  done
  [[ "$code" == 2?? ]] || die "Discord kept rate-limiting $repo; report not sent"
  sent=$((sent + 1))
done <<<"$payloads"

mkdir -p "$KOGUT_ROOT/.kogut/sent"
mv "$file" "$KOGUT_ROOT/.kogut/sent/$(date +%Y%m%d-%H%M%S)-$repo.md"
echo "sent to Discord: $repo ($sent message(s))"
