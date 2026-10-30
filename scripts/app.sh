#!/usr/bin/env bash
# The kogut GitHub App, the identity kogut acts under on GitHub. Its merges,
# commits and PRs show as <slug>[bot], so they stay apart from the owner's.
#
#   ./scripts/app.sh manifest              # opens the form that registers the App
#   ./scripts/app.sh convert <code>        # stores the App after GitHub redirects back
#   ./scripts/app.sh import <id> [<pem>]   # stores an App registered by hand
#   ./scripts/app.sh check                 # mints a token for every watched repository
#
# Registration uses GitHub's manifest flow. The form carries every setting, the
# owner only confirms it, and GitHub redirects to the homepage with ?code=… in
# the address bar. convert trades that one-time code for the App's private key.
# An App registered by hand instead (settings → Developer settings → GitHub
# Apps) is stored with import, from the key GitHub downloads; without a path it
# takes the newest <slug>.*.private-key.pem in ~/Downloads. Either way the key
# goes to ~/.config/kogut with mode 600 and is never printed, and the App id
# goes into kogut.config.json. Then the owner installs the App on the watched
# repositories.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: app.sh manifest | convert <code> | import <id> [<pem>] | check"

# Writes the App id into kogut.config.json with a targeted edit, which keeps
# the rest of the file as the owner formatted it.
set_app_id() {
  sed "s/\"id\": [0-9a-z]*,/\"id\": $1,/" "$KOGUT_CONFIG" >"$KOGUT_CONFIG.tmp" && mv "$KOGUT_CONFIG.tmp" "$KOGUT_CONFIG"
}
slug="$(kogut_app_slug)"
homepage="$(jq -r '.app.homepage' "$KOGUT_CONFIG")"

case "${1:-}" in
  manifest)
    [ -z "$(kogut_app_id)" ] || die "$slug is already registered (id $(kogut_app_id))"
    # The App can write code, PRs, issues and workflow files, and nothing else. It has
    # no webhook, because kogut runs on demand and never listens.
    manifest="$(jq -cn --arg name "$slug" --arg url "$homepage" --arg owner "$(kogut_owner)" '{
      name: $name,
      url: $url,
      description: "kogut, the maintenance agent for the \($owner) portfolio repositories. It merges Dependabot PRs that pass its policy and opens fix PRs for the owner to review.",
      public: false,
      redirect_url: $url,
      hook_attributes: {url: $url, active: false},
      request_oauth_on_install: false,
      setup_on_update: false,
      default_permissions: {metadata: "read", contents: "write", pull_requests: "write", issues: "write", workflows: "write"},
      default_events: []
    }')"
    page="$KOGUT_ROOT/.kogut/app-manifest.html"
    mkdir -p "$KOGUT_ROOT/.kogut"
    cat >"$page" <<EOF
<!doctype html>
<meta charset="utf-8">
<title>Register $slug</title>
<form action="https://github.com/settings/apps/new" method="post">
  <input type="hidden" name="manifest" value="$(jq -rn --arg m "$manifest" '$m | @html')">
  <p>This registers the GitHub App <b>$slug</b> under your account. GitHub shows every setting before you confirm.</p>
  <button type="submit">Register $slug on GitHub</button>
</form>
EOF
    if command -v open >/dev/null; then open "$page"; fi
    echo "registration form: $page"
    echo "after confirming, GitHub opens $homepage?code=…; run: ./scripts/app.sh convert <code>"
    ;;

  convert)
    [ $# -eq 2 ] || die "$usage"
    code="$2"
    # The whole redirect URL is accepted as well as the bare code.
    case "$code" in *code=*)
      code="${code#*code=}"
      code="${code%%&*}"
      ;;
    esac
    [[ "$code" =~ ^[A-Za-z0-9]+$ ]] || die "not a manifest code: $code"
    [ -z "$(kogut_app_id)" ] || die "$slug is already registered (id $(kogut_app_id))"
    key="$(kogut_app_key)"
    [ ! -e "$key" ] || die "a private key already exists at $key; move it away first"
    command -v curl >/dev/null || die "curl is not installed"
    resp="$(mktemp)"
    trap 'rm -f "$resp"' EXIT
    status="$(curl -sS -o "$resp" -w '%{http_code}' -X POST -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/app-manifests/$code/conversions")"
    [ "$status" = 201 ] || die "GitHub answered HTTP $status: $(jq -r '.message // empty' "$resp" 2>/dev/null)"
    id="$(jq -er '.id' "$resp")"
    [ "$(jq -r '.slug' "$resp")" = "$slug" ] ||
      die "GitHub registered the App as '$(jq -r '.slug' "$resp")', not '$slug'; set app.slug in kogut.config.json to match"
    (umask 077 && mkdir -p "$(dirname "$key")")
    (umask 077 && jq -er '.pem' "$resp" >"$key")
    set_app_id "$id"
    [ "$(kogut_app_id)" = "$id" ] || die "could not write the App id $id into kogut.config.json"
    echo "registered: $slug (id $id), private key at $key"
    echo "install it on the watched repositories: $(jq -r '.html_url' "$resp")/installations/new"
    ;;

  import)
    [ $# -ge 2 ] && [ $# -le 3 ] || die "$usage"
    id="$2"
    [[ "$id" =~ ^[0-9]+$ ]] || die "the App id is a number: $id"
    [ -z "$(kogut_app_id)" ] || die "$slug is already registered (id $(kogut_app_id))"
    pem="${3:-}"
    if [ -z "$pem" ]; then
      # shellcheck disable=SC2012 # the names are GitHub's, without spaces
      pem="$(ls -t "$HOME/Downloads/$slug".*.private-key.pem 2>/dev/null | head -n 1)" || true
      [ -n "$pem" ] || die "no $slug.*.private-key.pem in ~/Downloads; generate one in the App's settings"
    fi
    [ -f "$pem" ] || die "no such file: $pem"
    head -n 1 "$pem" | grep -qE '^-----BEGIN (RSA )?PRIVATE KEY-----$' || die "$pem is not a PEM private key"
    key="$(kogut_app_key)"
    [ ! -e "$key" ] || die "a private key already exists at $key; move it away first"
    command -v curl >/dev/null || die "curl is not installed"
    (umask 077 && mkdir -p "$(dirname "$key")")
    mv "$pem" "$key"
    chmod 600 "$key"
    set_app_id "$id"
    # GitHub answers /app only to a JWT signed with this App's key, so this
    # proves the id and the key belong together. On failure both are undone.
    if ! name="$(curl -fsS -H "Authorization: Bearer $(kogut_app_jwt)" \
      -H 'Accept: application/vnd.github+json' https://api.github.com/app | jq -er '.slug')" ||
      [ "$name" != "$slug" ]; then
      mv "$key" "$pem"
      set_app_id null
      die "GitHub did not accept the key for App $id as '$slug' (got '${name:-nothing}'); the key is back at $pem"
    fi
    echo "registered: $slug (id $id), private key at $key"
    echo "install it on the watched repositories: https://github.com/apps/$slug/installations/new"
    ;;

  check)
    [ -n "$(kogut_app_id)" ] || die "$slug is not registered: run ./scripts/app.sh manifest"
    failed=0
    while IFS= read -r repo; do
      if token="$(kogut_app_token "$repo" 2>/dev/null)" && [ -n "$token" ]; then
        echo "ok    $repo"
      else
        echo "FAIL  $repo → $slug is not installed there, or the key does not match"
        failed=1
      fi
    done < <(kogut_repos)
    bot="$(kogut_app_bot)"
    echo "acts as $bot (user id $(gh api "users/$bot" --jq .id 2>/dev/null || echo unknown))"
    exit "$failed"
    ;;

  *) die "$usage" ;;
esac
