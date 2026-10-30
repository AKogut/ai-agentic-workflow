#!/usr/bin/env bash
# Collects the maintenance state of the repositories in kogut.config.json.
#
#   ./scripts/collect.sh [repo ...]
#
# Writes the raw snapshot to .kogut/state.json, or to $KOGUT_STATE when set, and
# prints the signals digest computed from it by signals.jq: per repository, only
# what needs attention. The digest is compact JSON, so it fits in one read; pipe
# it to jq to browse.
# Read-only — nothing on GitHub is changed.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

owner="$(kogut_owner)"
window="$(kogut_policy run_window)"

repos=()
if [ $# -gt 0 ]; then
  for r in "$@"; do
    kogut_require_repo "$r"
    repos+=("$r")
  done
else
  while IFS= read -r r; do repos+=("$r"); done < <(kogut_repos)
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# `gh api` prints the error body on stdout even when it fails, so a plain
# `|| echo fallback` would leave invalid JSON behind. Prints the response, or
# $1 if the request failed.
api_or() {
  local fallback="$1" out
  shift
  if out="$(gh api "$@" 2>/dev/null)"; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$fallback"
  fi
}

# Raw state of one repository, as JSON on stdout.
collect_repo() {
  local repo="$1" full="$owner/$1" dir="$tmp/$1" branch id
  mkdir -p "$dir/runs"

  gh api "repos/$full" >"$dir/repo.json"
  branch="$(jq -r '.default_branch' "$dir/repo.json")"

  # pushed_at moves with a push to any branch, but scheduled workflows stop
  # after 60 days without commits on the default branch, so idleness is
  # measured from its head.
  local last_commit
  last_commit="$(api_or null "repos/$full/commits/$branch" --jq '.commit.committer.date | tojson')"

  gh pr list -R "$full" --state open --limit 100 \
    --json number,title,body,author,isDraft,createdAt,mergeable,mergeStateStatus,statusCheckRollup,headRefName,headRefOid,url \
    >"$dir/prs.json"

  # kogut's own PRs also carry their commits, reviews and comments, which the
  # follow-up rules in signals.jq read. Asked for separately, so the large
  # Dependabot list stays light, and capped at 10: GitHub refuses a query whose
  # nested commits and authors could exceed 500,000 nodes, and 100 PRs would.
  gh pr list -R "$full" --state open --limit 10 --author "app/$(kogut_app_slug)" \
    --json number,commits,reviews,comments >"$dir/kogut-prs.json"
  jq --slurpfile extra "$dir/kogut-prs.json" \
    'map(. as $pr | . + ([$extra[0][] | select(.number == $pr.number)][0] // {}))' \
    "$dir/prs.json" >"$dir/prs-merged.json" && mv "$dir/prs-merged.json" "$dir/prs.json"

  gh api "repos/$full/actions/workflows?per_page=100" \
    --jq '[.workflows[] | {id, name, path, state}]' >"$dir/workflows.json"

  # Runs on the default branch only: a red PR is the PR's business, a red main
  # is the repository's.
  for id in $(jq -r '.[] | select(.state == "active") | .id' "$dir/workflows.json"); do
    gh api "repos/$full/actions/workflows/$id/runs?branch=$branch&per_page=$window&exclude_pull_requests=true" \
      --jq "{\"$id\": [.workflow_runs[] | {id, event, status, conclusion, created_at, url: .html_url}]}" \
      >"$dir/runs/$id.json"
  done
  find "$dir/runs" -name '*.json' -exec cat {} + | jq -s 'add // {}' >"$dir/runs.json"

  # Required checks come from classic branch protection and from rulesets; the
  # rules endpoint returns only the rulesets that actually apply to the branch.
  {
    api_or '[]' "repos/$full/branches/$branch/protection/required_status_checks" --jq '[.checks[].context]'
    api_or '[]' "repos/$full/rules/branches/$branch" \
      --jq '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]'
  } | jq -s 'add | unique' >"$dir/required.json"

  # A repository can have more than one page of alerts. --jq runs once per
  # page, so it emits single alerts and jq -s gathers them.
  local alerts
  if alerts="$(gh api --paginate "repos/$full/dependabot/alerts?state=open&per_page=100" \
    --jq '.[] | {number, severity: .security_advisory.severity, package: .dependency.package.name,
            summary: .security_advisory.summary,
            patched: .security_vulnerability.first_patched_version.identifier, url: .html_url}' \
    2>"$dir/alerts.err")"; then
    jq -s '{status: "ok", items: .}' <<<"$alerts" >"$dir/alerts.json"
  elif grep -q 'disabled' "$dir/alerts.err"; then
    echo '{"status": "disabled", "items": []}' >"$dir/alerts.json"
  else
    echo '{"status": "unavailable", "items": []}' >"$dir/alerts.json"
  fi

  local dependabot_config=false
  if gh api "repos/$full/contents/.github/dependabot.yml" --silent 2>/dev/null ||
    gh api "repos/$full/contents/.github/dependabot.yaml" --silent 2>/dev/null; then
    dependabot_config=true
  fi

  local local_clone=false path
  path="$(kogut_repo_path "$repo")"
  [ -d "$path/.git" ] && local_clone=true

  jq -n \
    --arg name "$repo" \
    --arg path "$path" \
    --slurpfile repo "$dir/repo.json" \
    --slurpfile prs "$dir/prs.json" \
    --slurpfile workflows "$dir/workflows.json" \
    --slurpfile runs "$dir/runs.json" \
    --slurpfile required "$dir/required.json" \
    --slurpfile alerts "$dir/alerts.json" \
    --argjson last_commit "$last_commit" \
    --argjson dependabot_config "$dependabot_config" \
    --argjson local_clone "$local_clone" \
    '{
      name: $name,
      repo: ($repo[0] | {default_branch, pushed_at, html_url, allow_auto_merge, delete_branch_on_merge}
        + {last_commit_at: $last_commit}),
      prs: $prs[0],
      workflows: $workflows[0],
      runs: $runs[0],
      required_checks: $required[0],
      alerts: $alerts[0],
      dependabot_config: $dependabot_config,
      local_clone: {path: $path, present: $local_clone}
    }'
}

# One background job per repository. A repository that fails to collect is
# recorded with its error instead of aborting the whole sweep.
pids=()
for r in "${repos[@]}"; do
  (collect_repo "$r" >"$tmp/$r.json" 2>"$tmp/$r.log") &
  pids+=($!)
done
for i in "${!repos[@]}"; do
  r="${repos[$i]}"
  if ! wait "${pids[$i]}"; then
    jq -n --arg name "$r" --arg error "$(tail -n 3 "$tmp/$r.log")" '{name: $name, error: $error}' >"$tmp/$r.json"
  fi
done

state="${KOGUT_STATE:-$KOGUT_ROOT/.kogut/state.json}"
mkdir -p "$(dirname "$state")"
for r in "${repos[@]}"; do cat "$tmp/$r.json"; done |
  jq -s --arg owner "$owner" --slurpfile config "$KOGUT_CONFIG" \
    '{generated_at: (now | todate), owner: $owner, app: $config[0].app.slug, policy: $config[0].policy, repos: .}' >"$state"

jq -c -f "$KOGUT_ROOT/scripts/signals.jq" "$state"
