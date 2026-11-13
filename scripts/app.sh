#!/usr/bin/env bash
# The kogut GitHub App, the identity kogut acts under on GitHub. Its merges,
# commits and PRs show as <slug>[bot], so they stay apart from the owner's.
#
#   ./scripts/app.sh manifest              # opens the form that registers the App
#   ./scripts/app.sh convert <code>        # stores the App after GitHub redirects back
#   ./scripts/app.sh import <id> [<pem>]   # stores an App registered by hand
#   ./scripts/app.sh check                 # mints a token for every watched repository,
#                                          # names the ones it is not installed on yet,
#                                          # and says what reading as the App still lacks
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
# The App can write code, PRs, issues and workflow files, run workflows
# (actions) and dismiss Dependabot alerts (vulnerability_alerts), and nothing
# else. The manifest asks for these when the App is registered; on an App that
# exists already, the owner adds a new one in its settings.
app_permissions='{"metadata":"read","contents":"write","pull_requests":"write","issues":"write","workflows":"write","actions":"write","vulnerability_alerts":"write"}'

case "${1:-}" in
  manifest)
    [ -z "$(kogut_app_id)" ] || die "$slug is already registered (id $(kogut_app_id))"
    # It has no webhook, because kogut runs on demand and never listens.
    manifest="$(jq -cn --arg name "$slug" --arg url "$homepage" --arg owner "$(kogut_owner)" --argjson permissions "$app_permissions" '{
      name: $name,
      url: $url,
      description: "kogut, the maintenance agent for the \($owner) portfolio repositories. It merges Dependabot PRs that pass its policy and opens fix PRs for the owner to review.",
      public: false,
      redirect_url: $url,
      hook_attributes: {url: $url, active: false},
      request_oauth_on_install: false,
      setup_on_update: false,
      default_permissions: $permissions,
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
    # A repository the App is not installed on yet, such as one new to kogut, is
    # shown with the way to install it and does not fail the check: the scripts
    # that run over every repository skip it. Any other refusal fails.
    failed=0 first="" missing_on=""
    installed=()
    while IFS= read -r repo; do
      if token="$(kogut_app_token "$repo" 2>/dev/null)" && [ -n "$token" ]; then
        echo "ok    $repo"
        [ -n "$first" ] || first="$repo"
        installed+=("$repo")
      elif kogut_app_missing "$repo" >/dev/null; then
        echo "none  $repo → $slug is not installed there yet"
        missing_on="$missing_on $repo"
      else
        echo "FAIL  $repo → $slug is not installed there, or the key does not match"
        failed=1
      fi
    done < <(kogut_repos)
    [ -z "$missing_on" ] || echo "to install it on$missing_on: https://github.com/apps/$slug/installations/new"
    bot="$(kogut_app_bot)"
    echo "acts as $bot (user id $(gh api "users/$bot" --jq .id 2>/dev/null || echo unknown))"
    # What the owner has granted the installation, read on a repository it is
    # installed on. A permission added in the App's settings counts only once the
    # owner accepts it on the installation.
    if [ -n "$first" ] && granted="$(curl -fsS -H "Authorization: Bearer $(kogut_app_jwt)" -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/$(kogut_owner)/$first/installation" | jq -c '.permissions')"; then
      echo "granted: $(jq -r 'to_entries | map("\(.key): \(.value)") | join(", ")' <<<"$granted")"
      missing="$(jq -r --argjson want "$app_permissions" '. as $have | $want | to_entries
        | map(select($have[.key] != .value) | "\(.key): \(.value)") | join(", ")' <<<"$granted")"
      [ -z "$missing" ] || echo "not granted yet: $missing (the App's settings on GitHub, under Permissions, then accept on the installation)"
    else
      echo "granted: unknown"
    fi

    # Reading as the App (policy.read_as "app"): a token narrowed to the read side
    # of what it was granted, for every repository the App is installed on at
    # once. A read it may not make shows as unreadable, so the owner grants the
    # rest first. A repository new to kogut is named above and has nothing to ask for.
    read_as="$(kogut_read_as)"
    echo "reads as: $read_as (policy.read_as)"
    echo "reading as the App needs: $(jq -r 'keys_unsorted | map("\(.): read") | join(", ")' <<<"$KOGUT_READ_PERMISSIONS")"
    if [ -n "${granted:-}" ]; then
      echo "a read token carries: $(kogut_read_grants "$granted" | jq -r 'keys_unsorted | map("\(.): read") | join(", ")')"
      missing="$(jq -r --argjson want "$KOGUT_READ_PERMISSIONS" '. as $have | $want | keys_unsorted
        | map(select($have[.] == null) | "\(.): read") | join(", ")' <<<"$granted")"
      [ -z "$missing" ] || echo "not granted for reading: $missing (with read_as app, what needs them reads as unreadable)"
    fi
    if [ "${#installed[@]}" -eq 0 ]; then
      echo "none  no read token to ask for: $slug is installed on no watched repository"
    elif token="$(kogut_app_read_token "${installed[@]}" 2>/dev/null)" && [ -n "$token" ]; then
      echo "ok    a read token for every repository $slug is installed on"
    else
      echo "FAIL  no read token for the repositories $slug is installed on"
      [ "$read_as" = owner ] || failed=1
    fi
    exit "$failed"
    ;;

  *) die "$usage" ;;
esac
