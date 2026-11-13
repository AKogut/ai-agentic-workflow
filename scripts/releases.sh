#!/usr/bin/env bash
# The releases a lockfile change brings in, and when npm published them. kogut's
# own PRs wait for the same cooldown as Dependabot's on what they lock, as
# kogut_prs[] in signals.jq decides: collect.sh reads their lockfiles on GitHub,
# and fix-lockfile.sh names the youngest release before a PR is opened.
#
#   ./scripts/releases.sh new <before> <after>
#   ./scripts/releases.sh published <days>
#
# new prints the name@version pairs that <after> locks and <before> does not, one
# per line. The format comes from the file's name: package-lock.json or
# npm-shrinkwrap.json (lockfile version 2 or 3), or pnpm-lock.yaml (lockfile
# version 6 or later). A <before> that does not exist locks nothing. Local
# packages (workspaces, file: and link:) are not releases and are left out. A
# package from anywhere but the npm registry keeps its source in place of the
# version, which npm then cannot date. A format kogut does not read fails.
#
# published reads such pairs on stdin and prints, as JSON, how many there are
# (`count`), the youngest, every one npm published less than <days> days ago
# (`recent`, youngest first) and what it could not date (`unread`): a name it
# does not look up, a package or version npm does not have, a version npm took
# down, or more packages than KOGUT_RELEASE_LOOKUPS (200). Nothing it cannot
# date passes for old. Each package's answer is kept in KOGUT_NPM_CACHE when
# that is set, so a run asks npm once per package.
set -euo pipefail
# sort and comm must agree on one order, whatever the machine's locale.
export LC_ALL=C

die() {
  echo "releases: $*" >&2
  exit 1
}

# What a lockfile locks, one name@version per line.
locked() {
  local file="$1" version
  case "${file##*/}" in
    package-lock.json | npm-shrinkwrap.json)
      jq -r '
        if (.lockfileVersion | type) == "number" and .lockfileVersion >= 2 and (.packages | type) == "object"
        then . else error("lockfile version \(.lockfileVersion) is not one kogut reads") end
        | .packages | to_entries[]
        | select((.key | test("(^|/)node_modules/")) and .value.link != true)
        | (.value.resolved // "") as $from
        | select($from | startswith("file:") | not)
        | "\(.value.name // (.key | sub("^.*node_modules/"; "")))@\(
            if $from == "" or ($from | test("^https://registry\\.(npmjs\\.org|yarnpkg\\.com)/"))
            then .value.version else $from end)"' "$file"
      ;;
    pnpm-lock.yaml)
      version="$(sed -nE "s/^lockfileVersion: *['\"]?([0-9]+)[.0-9]*['\"]? *$/\1/p" "$file" | head -n 1)"
      [ -n "$version" ] && [ "$version" -ge 6 ] ||
        die "${file##*/}: lockfile version ${version:-unknown} is not one kogut reads"
      # The keys under packages:, such as vite@8.3.8, '@scope/name@1.2.3', or in
      # version 6 /vite@5.0.0(peer@1.0.0).
      awk '/^packages:/ { p = 1; next } /^[^ ]/ { p = 0 } p && /^  [^ #]/ { k = substr($0, 3); sub(/:[ ]*$/, "", k); print k }' "$file" |
        jq -R -r '([39] | implode) as $q | gsub("^[\($q)\"]|[\($q)\"]$"; "") | ltrimstr("/") | sub("\\(.*$"; "")
          | ([capture("^(?<name>@[^/@]+/[^@]+|[^@]+)@(?<spec>.+)$")] | first) as $c
          | if $c == null then .
            elif $c.spec | test("^(file|link|workspace):") then empty
            else "\($c.name)@\($c.spec)" end'
      ;;
    *) die "${file##*/} is not a lockfile kogut reads" ;;
  esac
}

new() {
  local before="$1" after="$2" a b
  a="$(locked "$after" | sort -u)"
  b=""
  if [ -e "$before" ]; then b="$(locked "$before" | sort -u)"; fi
  comm -13 <(printf '%s\n' "$b" | sed '/^$/d') <(printf '%s\n' "$a" | sed '/^$/d')
}

# Keeps npm's answer on one package in the cache: its publish times and the
# versions it still has, or that it has none, or the error. Written whole or not
# at all, so runs that share the cache never read half an answer.
ask_npm() {
  local name="$1" cache="$2" file part code
  file="$cache/${name/\//%2F}.json"
  part="$(mktemp "$cache/.part.XXXXXX")"
  code="$(curl -s --compressed --max-time 60 -o "$part" -w '%{http_code}' \
    "https://registry.npmjs.org/${name/\//%2F}" 2>/dev/null)" || code="${code:-000}"
  if [ "$code" = 200 ] && jq -c '{time: (.time // {}), versions: (.versions // {} | keys)}' "$part" >"$part.json" 2>/dev/null; then
    mv "$part.json" "$file"
  elif [ "$code" = 404 ]; then
    echo '{"missing": true}' >"$part.json" && mv "$part.json" "$file"
  else
    jq -n --arg code "$code" '{error: "HTTP \($code)"}' >"$part.json" && mv "$part.json" "$file"
  fi
  rm -f "$part" "$part.json"
}

published() {
  local days="$1" limit="${KOGUT_RELEASE_LOOKUPS:-200}" cache="${KOGUT_NPM_CACHE:-}" list names count
  [[ "$days" =~ ^[0-9]+$ ]] || die "the cooldown is not a number of days: $days"
  [[ "$limit" =~ ^[0-9]+$ ]] || die "KOGUT_RELEASE_LOOKUPS is not a number: $limit"
  if [ -z "$cache" ]; then
    cache="$(mktemp -d)"
    # shellcheck disable=SC2064 # the path is fixed now
    trap "rm -rf '$cache'" EXIT
  fi
  mkdir -p "$cache"

  # Each pair as {name, version}; a name kogut does not look up, or a source in
  # place of a version, is never sent to the registry.
  list="$(sed '/^$/d' | sort -u | jq -R -s -c '[split("\n")[] | select(. != "")
    | ([capture("^(?<name>@[^/@]+/[^@]+|[^@]+)@(?<version>.+)$")] | first) // {name: ., version: null}
    | . + {asked: ((.name | test("^(@[A-Za-z0-9._~-]+/)?[A-Za-z0-9._~-]+$"))
        and (.version // "" | test("^[0-9]+\\.[0-9]+\\.[0-9]+([-+][0-9A-Za-z.+-]+)?$")))}]')"
  names="$(jq -r '[.[] | select(.asked) | .name] | unique[]' <<<"$list")"
  count="$(printf '%s' "$names" | grep -c . || true)"
  if [ "$count" -gt "$limit" ]; then
    jq -n --argjson list "$list" --argjson count "$count" --argjson limit "$limit" \
      '{count: ($list | length), youngest: null, recent: [],
        unread: ["\($list | length) new releases from \($count) packages, and kogut looks up at most \($limit)"]}'
    return
  fi

  # Eight packages at a time, since one large package can take seconds.
  local name running=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -s "$cache/${name/\//%2F}.json" ] && continue
    ask_npm "$name" "$cache" &
    running=$((running + 1))
    if [ "$running" -ge 8 ]; then
      wait
      running=0
    fi
  done <<<"$names"
  wait

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ -s "$cache/${name/\//%2F}.json" ]; then
      jq -c --arg n "$name" '{($n): .}' "$cache/${name/\//%2F}.json"
    else
      jq -cn --arg n "$name" '{($n): {error: "no answer"}}'
    fi
  done <<<"$names" | jq -s --argjson list "$list" --argjson days "$days" '
    def now_ts: if $ENV.KOGUT_NOW then $ENV.KOGUT_NOW | fromdateiso8601 else now end;
    def short: if length > 120 then .[:117] + "..." else . end;
    (add // {}) as $npm
    | [$list[] | . as $x | ($npm[.name] // {}) as $e
        | "\(.name)@\(.version // "?")" as $id
        | if (.asked | not) then {unread: "\($id | short) is not a release on the npm registry"}
          elif $e.error then {unread: "the npm registry did not answer for \(.name) (\($e.error))"}
          elif $e.missing then {unread: "\(.name) is not on the npm registry"}
          elif ($e.versions | index([$x.version]) | not) then
            (if $e.time[$x.version] then {unread: "\($id) was taken down from the npm registry"}
             else {unread: "the npm registry has no \($id)"} end)
          else
            ($e.time[$x.version] // "" | try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null) as $ts
            | if $ts == null then {unread: "the npm registry gives no publish time for \($id)"}
              else {name, version, published_at: ($ts | todate), ts: $ts} end
          end] as $all
    | [$all[] | select(.ts)] as $dated
    | [$all[] | .unread // empty] as $unread
    | {
        count: ($list | length),
        youngest: ($dated | max_by(.ts) | if . then del(.ts) else null end),
        recent: ([$dated[] | select(now_ts - .ts < $days * 86400)] | sort_by(-.ts, .name) | map(del(.ts))),
        unread: (if ($unread | length) > 20 then $unread[:20] + ["and \(($unread | length) - 20) more"] else $unread end)
      }'
}

[ $# -ge 1 ] || die "usage: releases.sh new <before> <after> | published <days>"
case "$1" in
  new)
    [ $# -eq 3 ] || die "usage: releases.sh new <before> <after>"
    new "$2" "$3"
    ;;
  published)
    [ $# -eq 2 ] || die "usage: releases.sh published <days>"
    published "$2"
    ;;
  *) die "usage: releases.sh new <before> <after> | published <days>" ;;
esac
