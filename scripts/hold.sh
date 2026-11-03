#!/usr/bin/env bash
# The owner's stop switch: while a repository is on hold, every script that writes
# on GitHub refuses it, and issues.sh and auto-merge.sh skip it. The daily digest
# keeps running, because it only reads, and says the repository is on hold.
#
#   ./scripts/hold.sh on [repo ...] [--reason <text>]   # no repo means all of them
#   ./scripts/hold.sh off [repo ...]                    # no repo means all of them
#   ./scripts/hold.sh status [repo ...]
#
# The state is ~/.config/kogut/hold.json, or $KOGUT_HOLD_FILE, outside the
# repository, so a run from any worktree sees it. A file that cannot be read holds
# every repository, and this script will not overwrite it: fix or remove it by hand.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: hold.sh on [repo ...] [--reason <text>] | off [repo ...] | status [repo ...]"
[ $# -ge 1 ] || die "$usage"
action="$1"
shift
case "$action" in on | off | status) ;; *) die "$usage" ;; esac

reason="" names=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reason)
      [ "$action" = on ] && [ $# -ge 2 ] && [ -n "$2" ] || die "$usage"
      reason="$2"
      shift
      ;;
    -*) die "$usage" ;;
    *)
      kogut_require_repo "$1"
      names="$names $1"
      ;;
  esac
  shift
done
[ -n "$names" ] || names="$(kogut_repos | tr '\n' ' ')"

file="$(kogut_hold_file)"

show() {
  local repo why
  for repo in $names; do
    if why="$(kogut_held "$repo")"; then
      echo "$repo: $why"
    else
      echo "$repo: not on hold"
    fi
  done
}

if [ "$action" = status ]; then
  show
  exit 0
fi

current='{"repos":{}}'
if [ -e "$file" ] || [ -L "$file" ]; then
  current="$(jq -ces 'if length == 1 and (.[0] | type) == "object" and (.[0].repos | type) == "object" then .[0] else error("not a hold file") end' "$file" 2>/dev/null)" ||
    die "$file cannot be read, so every repository stays on hold. Fix or remove it by hand"
fi

since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
next="$current"
for repo in $names; do
  if [ "$action" = on ]; then
    # shellcheck disable=SC2016 # these are jq's variables
    next="$(jq -c --arg r "$repo" --arg s "$since" --arg w "$reason" \
      '.repos[$r] = ({since: $s} + (if $w == "" then {} else {reason: $w} end))' <<<"$next")"
  else
    # shellcheck disable=SC2016 # this is jq's variable
    next="$(jq -c --arg r "$repo" 'del(.repos[$r])' <<<"$next")"
  fi
done

mkdir -p "$(dirname "$file")"
tmp="$(mktemp "$file.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
jq . <<<"$next" >"$tmp"
chmod 600 "$tmp"
mv "$tmp" "$file"

show
