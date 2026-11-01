#!/usr/bin/env bash
# What kogut did in the watched repositories over a window, next to what the
# owner did: merges, kogut's PRs and issues, its comments, and the Dependabot
# alerts that closed.
#
#   ./scripts/progress.sh [--days N | --since YYYY-MM-DD] [--json] [repo ...]
#
# Prints a markdown report, or with --json the figures behind it; progress.jq
# does the counting. The window is the last 7 days unless given. Read-only.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: progress.sh [--days N | --since YYYY-MM-DD] [--json] [repo ...]"
days=7 since="" format=markdown named=0
repos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --days)
      [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || die "$usage"
      days="$2"
      shift 2
      ;;
    --since)
      [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "$usage"
      since="$2"
      shift 2
      ;;
    --json)
      format=json
      shift
      ;;
    -*) die "$usage" ;;
    *)
      kogut_require_repo "$1"
      repos+=("$1")
      named=1
      shift
      ;;
  esac
done
if [ "$named" -eq 0 ]; then
  while IFS= read -r r; do repos+=("$r"); done < <(kogut_repos)
fi
[ -n "$since" ] || since="$(jq -rn --argjson d "$days" '(now - $d * 86400) | strftime("%Y-%m-%d")')"

owner="$(kogut_owner)"
slug="$(kogut_app_slug)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# GitHub's search covers every repository of the owner in one query, private
# ones included; progress.jq keeps only the watched ones.
# shellcheck disable=SC2016 # $q and $endCursor are GraphQL variables
search_query='
  query($q: String!, $endCursor: String) {
    search(query: $q, type: ISSUE, first: 100, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes {
        __typename
        ... on PullRequest {
          number title url state createdAt closedAt mergedAt
          repository { name } author { login } mergedBy { login }
        }
        ... on Issue {
          number title url state createdAt closedAt
          repository { name } author { login }
          timelineItems(itemTypes: CLOSED_EVENT, last: 1) { nodes { ... on ClosedEvent { actor { login } } } }
        }
      }
    }
  }'
search() {
  gh api graphql --paginate -f q="$1" -f query="$search_query" --jq '.data.search.nodes[]' | jq -s .
}

# Per repository: kogut's comments in the window, and its Dependabot alerts.
# The comments endpoint filters by last update, so progress.jq checks when each
# was written.
figures() {
  local full="$owner/$1" status=ok
  api_or '' --paginate "repos/$full/issues/comments?since=${since}T00:00:00Z&per_page=100" \
    --jq ".[] | select(.user.login == \"${slug}[bot]\") | {created_at, url: .html_url, body: (.body | split(\"\\n\")[0] | .[0:120])}" |
    jq -s . >"$tmp/$1.comments.json"
  local state
  for state in fixed open; do
    if ! gh api --paginate "repos/$full/dependabot/alerts?state=$state&per_page=100" \
      --jq '.[] | {severity: .security_advisory.severity, fixed_at}' >"$tmp/$1.$state.raw" 2>/dev/null; then
      status=unavailable
      : >"$tmp/$1.$state.raw"
    fi
    jq -s . "$tmp/$1.$state.raw" >"$tmp/$1.$state.json"
  done
  jq -n --arg name "$1" --arg status "$status" \
    --slurpfile comments "$tmp/$1.comments.json" --slurpfile fixed "$tmp/$1.fixed.json" --slurpfile open "$tmp/$1.open.json" \
    '{name: $name, comments: $comments[0], alerts: {status: $status, fixed: $fixed[0], open: $open[0]}}'
}

search "user:$owner author:app/$slug" >"$tmp/kogut.json" &
kogut_pid=$!
search "user:$owner is:pr is:merged merged:>=$since" >"$tmp/merged.json" &
merged_pid=$!
pids=()
for r in "${repos[@]}"; do
  figures "$r" >"$tmp/$r.figures.json" &
  pids+=($!)
done
wait "$kogut_pid" || die "the search for kogut's PRs and issues failed"
wait "$merged_pid" || die "the search for merged PRs failed"
for pid in "${pids[@]}"; do wait "$pid" || die "collecting a repository's comments and alerts failed"; done

for r in "${repos[@]}"; do cat "$tmp/$r.figures.json"; done | jq -s . >"$tmp/figures.json"
jq -n --arg since "$since" --arg owner "$owner" --arg app "$slug" \
  --argjson repos "$(printf '%s\n' "${repos[@]}" | jq -R . | jq -sc .)" \
  --slurpfile kogut "$tmp/kogut.json" --slurpfile merged "$tmp/merged.json" --slurpfile figures "$tmp/figures.json" \
  '{since: $since, until: (now | strftime("%Y-%m-%d")), owner: $owner, app: $app, repos: $repos,
    kogut: $kogut[0], merged: $merged[0], figures: $figures[0]}' >"$tmp/input.json"

jq -r --arg format "$format" -f "$KOGUT_ROOT/scripts/progress.jq" "$tmp/input.json"
