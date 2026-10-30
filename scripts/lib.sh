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

# Default branch of a configured repository: the local clone's origin/HEAD, or
# GitHub's answer when the clone does not record it.
kogut_default_branch() {
  local dir branch
  dir="$(kogut_repo_path "$1")"
  branch="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  branch="${branch#origin/}"
  if [ -z "$branch" ]; then
    branch="$(gh repo view "$(kogut_owner)/$1" --json defaultBranchRef --jq .defaultBranchRef.name)"
  fi
  echo "$branch"
}

# The kogut GitHub App (scripts/app.sh registers it). The id is empty until then.
kogut_app_id() { jq -r '.app.id // empty' "$KOGUT_CONFIG"; }
kogut_app_slug() { jq -r '.app.slug' "$KOGUT_CONFIG"; }
kogut_app_bot() { echo "$(kogut_app_slug)[bot]"; }

# The App's private key lives outside the repository, and a deny rule keeps the
# model from reading it. Only kogut_app_token opens it.
kogut_app_key() { echo "${KOGUT_APP_KEY:-$HOME/.config/kogut/$(kogut_app_slug).private-key.pem}"; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# A JWT that proves to GitHub the caller holds the App's key, valid for nine
# minutes. It is only good for asking GitHub for installation tokens.
kogut_app_jwt() {
  local id key now header claims signature
  id="$(kogut_app_id)"
  [ -n "$id" ] || die "the kogut App is not registered: see ./scripts/app.sh"
  key="$(kogut_app_key)"
  [ -r "$key" ] || die "the App's private key is missing: $key"
  command -v openssl >/dev/null || die "openssl is not installed"
  now="$(date +%s)"
  header="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)"
  claims="$(printf '{"iat":%d,"exp":%d,"iss":%d}' "$((now - 60))" "$((now + 540))" "$id" | b64url)"
  signature="$(printf '%s.%s' "$header" "$claims" | openssl dgst -sha256 -sign "$key" -binary | b64url)"
  echo "$header.$claims.$signature"
}

# An installation token for one watched repository, valid for an hour. Every
# write kogut makes on GitHub uses it, so the write shows as the App's bot and
# cannot bypass a ruleset the way the owner's token can. Assign it to a variable
# and check it before use: in `GH_TOKEN="$(kogut_app_token r)" gh …` a failure
# would leave GH_TOKEN empty, and gh would quietly fall back to the owner.
kogut_app_token() {
  local repo="$1" jwt installation
  command -v curl >/dev/null || die "curl is not installed"
  jwt="$(kogut_app_jwt)" || exit 1
  installation="$(curl -fsS -H "Authorization: Bearer $jwt" -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$(kogut_owner)/$repo/installation" | jq -er '.id')" ||
    die "the kogut App is not installed on $repo"
  curl -fsS -X POST -H "Authorization: Bearer $jwt" -H 'Accept: application/vnd.github+json' \
    --data "$(jq -cn --arg r "$repo" '{repositories: [$r]}')" \
    "https://api.github.com/app/installations/$installation/access_tokens" | jq -er '.token' ||
    die "GitHub refused an installation token for $repo"
}
