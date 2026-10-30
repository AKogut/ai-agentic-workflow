#!/usr/bin/env bash
# Read-only look into a watched repository as of its default branch on GitHub,
# never the working copy, which may be on any branch with any local edits.
#
#   ./scripts/repo.sh <repo> grep <extended-regex> [pathspec ...]
#   ./scripts/repo.sh <repo> show <path>
#   ./scripts/repo.sh <repo> ls [dir]
#   ./scripts/repo.sh <repo> log [path]
#
# Reads the local clone from kohut.config.json. The fetch updates only the
# remote-tracking ref, so the working tree is left alone.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: repo.sh <repo> grep <regex> [pathspec ...] | show <path> | ls [dir] | log [path]"
[ $# -ge 2 ] || die "$usage"
repo="$1" cmd="$2"
shift 2
kohut_require_repo "$repo"
dir="$(kohut_repo_path "$repo")"
[ -d "$dir/.git" ] || die "no local clone of $repo at $dir"

branch="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
branch="${branch#origin/}"
if [ -z "$branch" ]; then
  branch="$(gh repo view "$(kohut_owner)/$repo" --json defaultBranchRef --jq .defaultBranchRef.name)"
fi
git -C "$dir" fetch --quiet origin "$branch"
ref="origin/$branch"

# Caps output without closing the pipe early, which would kill git with
# SIGPIPE under pipefail.
cap() { awk -v max="$1" 'NR <= max { print } END { if (NR > max) print "... " NR - max " more lines" }'; }

case "$cmd" in
  grep)
    [ $# -ge 1 ] || die "$usage"
    pattern="$1"
    shift
    [ $# -gt 0 ] || set -- .
    git -C "$dir" grep -n -I -E -e "$pattern" "$ref" -- "$@" \
      ':(exclude,glob)**/package-lock.json' ':(exclude,glob)**/yarn.lock' ':(exclude,glob)**/pnpm-lock.yaml' \
      | sed "s#^$ref:##" | cap 200 || echo "(no matches)"
    ;;
  show)
    [ $# -eq 1 ] || die "$usage"
    git -C "$dir" show "$ref:$1" | cap 400
    ;;
  ls)
    git -C "$dir" ls-tree --name-only "$ref:${1:-}"
    ;;
  log)
    git -C "$dir" log -30 --date=short --format='%h %ad %s' "$ref" -- "${1:-.}"
    ;;
  *)
    die "$usage"
    ;;
esac
