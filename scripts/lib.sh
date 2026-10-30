# Shared helpers for kogut scripts. Sourced, not executed.
# shellcheck shell=bash

KOGUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KOGUT_CONFIG="$KOGUT_ROOT/kogut.config.json"

die() {
  echo "kogut: $*" >&2
  exit 1
}

command -v gh >/dev/null || die "gh is not installed"
command -v jq >/dev/null || die "jq is not installed"
[ -f "$KOGUT_CONFIG" ] || die "missing $KOGUT_CONFIG"

kogut_owner() { jq -r '.owner' "$KOGUT_CONFIG"; }

kogut_policy() { jq -r --arg k "$1" '.policy[$k]' "$KOGUT_CONFIG"; }

# Every configured repository name, one per line.
kogut_repos() { jq -r '.repos[].name' "$KOGUT_CONFIG"; }

# Scripts only ever touch the configured repositories, so every name that comes
# in as an argument is checked here first.
kogut_require_repo() {
  jq -e --arg r "$1" 'any(.repos[]; .name == $r)' "$KOGUT_CONFIG" >/dev/null ||
    die "'$1' is not in kogut.config.json (known: $(kogut_repos | paste -sd, -))"
}

# Local clone of a configured repository, with ~ expanded.
kogut_repo_path() {
  local p
  p="$(jq -r --arg r "$1" '.repos[] | select(.name == $r) | .path' "$KOGUT_CONFIG")"
  echo "${p/#\~/$HOME}"
}
