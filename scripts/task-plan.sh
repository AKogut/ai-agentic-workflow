#!/usr/bin/env bash
# Says which tasks and feature requests to start now, and which wait, as
# task-plan.jq decides. /kogut tasks starts one agent per entry in run. Read-only.
#
#   ./scripts/task-plan.sh [repo ...]
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

state="$(mktemp)"
trap 'rm -f "$state"' EXIT
digest="$(KOGUT_STATE="$state" "$KOGUT_ROOT/scripts/collect.sh" "$@")"

holds='{}' busy='{}'
while IFS= read -r repo; do
  if why="$(kogut_held "$repo")"; then
    # shellcheck disable=SC2016 # these are jq's variables
    holds="$(jq -c --arg r "$repo" --arg w "$why" '.[$r] = $w' <<<"$holds")"
  fi
  slugs="$(kogut_fix_worktrees "$repo" | jq -Rsc 'split("\n") | map(select(. != ""))')"
  # shellcheck disable=SC2016 # these are jq's variables
  busy="$(jq -c --arg r "$repo" --argjson s "$slugs" '.[$r] = $s' <<<"$busy")"
done < <(jq -r '.repos[].name' <<<"$digest")

# shellcheck disable=SC2016 # these are jq's variables
jq -n --argjson digest "$digest" --argjson holds "$holds" --argjson busy "$busy" \
  --argjson limit "$(jq '.policy.parallel_agents // 1' "$KOGUT_CONFIG")" \
  '{repos: $digest.repos, holds: $holds, busy: $busy, limit: $limit}' |
  jq -f "$KOGUT_ROOT/scripts/task-plan.jq"
