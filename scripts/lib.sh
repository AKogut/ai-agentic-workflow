# Shared helpers for kohut scripts. Sourced, not executed.
# shellcheck shell=bash

KOHUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KOHUT_CONFIG="$KOHUT_ROOT/kohut.config.json"

die() {
  echo "kohut: $*" >&2
  exit 1
}

command -v gh >/dev/null || die "gh is not installed"
command -v jq >/dev/null || die "jq is not installed"
[ -f "$KOHUT_CONFIG" ] || die "missing $KOHUT_CONFIG"

kohut_owner() { jq -r '.owner' "$KOHUT_CONFIG"; }

kohut_policy() { jq -r --arg k "$1" '.policy[$k]' "$KOHUT_CONFIG"; }

# Every configured repository name, one per line.
kohut_repos() { jq -r '.repos[].name' "$KOHUT_CONFIG"; }

# Scripts only ever touch the configured repositories, so every name that comes
# in as an argument is checked here first.
kohut_require_repo() {
  jq -e --arg r "$1" 'any(.repos[]; .name == $r)' "$KOHUT_CONFIG" >/dev/null ||
    die "'$1' is not in kohut.config.json (known: $(kohut_repos | paste -sd, -))"
}

# Local clone of a configured repository, with ~ expanded.
kohut_repo_path() {
  local p
  p="$(jq -r --arg r "$1" '.repos[] | select(.name == $r) | .path' "$KOHUT_CONFIG")"
  echo "${p/#\~/$HOME}"
}
