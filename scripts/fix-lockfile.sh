#!/usr/bin/env bash
# Regenerates a lockfile in a fix's worktree after the model changed a
# manifest: an `overrides` entry for a transitive dependency that Dependabot
# cannot move, or the dependencies of a migration. The package manager writes
# the lockfile and nothing else: no node_modules, no lifecycle scripts, no
# pnpmfile hooks, so no package code runs on this machine.
#
#   ./scripts/fix-lockfile.sh <repo> <slug> [<dir>]
#
# <dir> is the project inside the worktree, its root by default. npm
# (package-lock.json) and pnpm (pnpm-lock.yaml) are supported. pnpm has to be
# the version the repository's packageManager names, and npm has to write the
# lockfile version already there, so the lockfile keeps its format. The
# script refuses when the fix touches .npmrc or a pnpmfile, which change how
# the package manager runs. Afterwards it lists the versions that changed and,
# for the critical and high alerts of that project, what the lockfile now
# holds next to the versions that fix them.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: fix-lockfile.sh <repo> <slug> [<dir>]"
[ $# -ge 2 ] && [ $# -le 3 ] || die "$usage"
repo="$1" slug="$2" dir="${3:-.}"
kogut_require_repo "$repo"
[[ "$slug" =~ ^[a-z0-9][a-z0-9-]{1,48}$ ]] || die "not a fix slug: $slug"
worktree="$KOGUT_ROOT/.kogut/fixes/$repo/$slug"
[ -d "$worktree" ] || die "there is no fix $repo/$slug: start it with fix-start.sh"
case "$dir" in /* | *..*) die "the project must be a directory inside the worktree: $dir" ;; esac
dir="${dir%/}"
project="$worktree/$dir"
[ -d "$project" ] || die "no directory $dir in the worktree"

# Configuration that changes how the package manager runs is not a fix's to change.
if git -C "$worktree" status --porcelain --untracked-files=all | sed 's/^...//' |
  grep -qE '(^|/)(\.npmrc|\.pnpmfile\.c?js|\.pnpmfile\.mjs|\.yarnrc(\.yml)?)$'; then
  die "the fix changes package manager configuration (.npmrc or a pnpmfile); refusing to run it"
fi

if [ -f "$project/pnpm-lock.yaml" ]; then
  manager=pnpm lock=pnpm-lock.yaml
elif [ -f "$project/package-lock.json" ]; then
  manager=npm lock=package-lock.json
else
  die "no package-lock.json or pnpm-lock.yaml in $dir"
fi
[ ! -f "$project/yarn.lock" ] || echo "note: $dir/yarn.lock is left as it is"

# No GitHub token reaches the package manager, and no scripts, audit or notices run.
run() {
  (cd "$project" && env -u GH_TOKEN -u GITHUB_TOKEN npm_config_ignore_scripts=true npm_config_audit=false \
    npm_config_fund=false npm_config_update_notifier=false "$@")
}

# name → versions in a lockfile, as JSON, for the summary below.
versions() {
  if [ "$manager" = pnpm ]; then
    awk '/^packages:/ { p = 1; next } /^[^ ]/ { p = 0 } p && /^  [^ ]/' "$1" |
      sed -E "s/^  '?(@?[^@']+)@([^:'(]+).*/\1 \2/" |
      jq -R -n '[inputs | split(" ") | {name: .[0], version: .[1]}] | group_by(.name) | map({key: .[0].name, value: (map(.version) | unique)}) | from_entries'
  else
    jq '[.packages | to_entries[] | select(.key != "") | {name: (.key | sub(".*node_modules/"; "")), version: .value.version}]
        | group_by(.name) | map({key: .[0].name, value: (map(.version) | unique)}) | from_entries' "$1"
  fi
}

before="$(mktemp)"
trap 'rm -f "$before"' EXIT
cp "$project/$lock" "$before"
existing_modules="$(find "$worktree" -name node_modules -type d -prune 2>/dev/null | sort)"

case "$manager" in
  pnpm)
    want="$(jq -r '.packageManager // empty' "$project/package.json" 2>/dev/null)"
    want="${want%%+*}"
    [[ "$want" == pnpm@* ]] || die "$dir/package.json names no pnpm version in packageManager"
    [ "pnpm@$(pnpm --version)" = "$want" ] || die "the repository wants $want, but pnpm here is $(pnpm --version)"
    run pnpm install --lockfile-only --ignore-scripts --ignore-pnpmfile --reporter=append-only
    ;;
  npm)
    format="$(jq -r '.lockfileVersion' "$project/package-lock.json")"
    [ "$format" = 3 ] || die "$dir/package-lock.json is lockfile version $format, and npm $(npm --version) writes 3"
    run npm install --package-lock-only --ignore-scripts --no-audit --no-fund
    ;;
esac

# A lockfile-only run must leave no node_modules behind.
if [ "$(find "$worktree" -name node_modules -type d -prune 2>/dev/null | sort)" != "$existing_modules" ]; then
  find "$worktree" -name node_modules -type d -prune -exec rm -rf {} +
  die "the package manager created node_modules; they were removed, and the lockfile change should not be trusted"
fi

echo "--- $dir/$lock"
git -C "$worktree" diff --stat -- "$dir/$lock" | tail -n 1
echo "--- versions that changed"
jq -r -n --argjson a "$(versions "$before")" --argjson b "$(versions "$project/$lock")" '
  ($a + $b | keys) as $names
  | [$names[] | select($a[.] != $b[.]) | "\(.): \($a[.] // [] | join(", ") | if . == "" then "-" else . end) → \($b[.] // [] | join(", ") | if . == "" then "-" else . end)"]
  | if . == [] then "(none)" else .[] end'

# The project's critical and high alerts, from the run's snapshot, against
# what the lockfile holds now. GitHub closes an alert itself once the fix is
# on the default branch; this is a check before that.
state="$KOGUT_ROOT/.kogut/state.json"
if [ -f "$state" ]; then
  echo "--- critical and high alerts in $dir (from the last collection)"
  jq -r -n --slurpfile s "$state" --arg r "$repo" --arg dir "$dir" --argjson now "$(versions "$project/$lock")" '
    [$s[0].repos[] | select(.name == $r) | .alerts.items[]?
      | select(.severity | IN("critical", "high"))
      | select((.manifest // "") | (if contains("/") then sub("/[^/]*$"; "") else "." end) == $dir)]
    | group_by(.package)
    | map("\(.[0].package) (\(map(.severity) | unique | join("/"))): now \($now[.[0].package] // [] | join(", ") | if . == "" then "absent" else . end) · fixed in \([.[].patched // empty] | unique | join(" / ") | if . == "" then "no release yet" else . end)")
    | if . == [] then "(none)" else .[] end'
fi
