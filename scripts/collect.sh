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

# Prints a file from a repository's default branch. Returns 1 when the file does
# not exist and 2 when it could not be read, so a failed request cannot pass for
# a missing file.
branch_file() {
  local full="$1" branch="$2" path="$3" err="$4" out
  if out="$(gh api -H 'Accept: application/vnd.github.raw' "repos/$full/contents/$path?ref=$branch" 2>"$err")"; then
    printf '%s\n' "$out"
    return 0
  fi
  grep -q 'HTTP 404' "$err" && return 1
  return 2
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
  last_commit="$(api_or '{}' "repos/$full/commits/$branch" --jq '{sha, date: .commit.committer.date}')"

  gh pr list -R "$full" --state open --limit 100 \
    --json number,title,body,author,isDraft,createdAt,mergeable,mergeStateStatus,statusCheckRollup,headRefName,headRefOid,baseRefName,url \
    >"$dir/prs.json"

  # kogut's own PRs also carry their commits, reviews and comments, which the
  # follow-up rules in signals.jq read. Asked for separately, so the large
  # Dependabot list stays light, and capped at 10: GitHub refuses a query whose
  # nested commits and authors could exceed 500,000 nodes, and 100 PRs would.
  gh pr list -R "$full" --state open --limit 10 --author "app/$(kogut_app_slug)" \
    --json number,commits,reviews,comments >"$dir/kogut-prs.json"
  # Dependabot's PRs carry the date of their head commit and their latest
  # comments, where Dependabot says why it cannot rebase and where kogut's own
  # commands show. Asking for the last few of each keeps the query small.
  # shellcheck disable=SC2016 # $owner and $name are GraphQL variables
  api_or '[]' graphql -F owner="$owner" -F name="$repo" -f query='
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        pullRequests(states: OPEN, first: 100) {
          nodes {
            number
            author { login }
            commits(last: 1) { nodes { commit { committedDate } } }
            comments(last: 10) { nodes { author { login } createdAt body } }
          }
        }
      }
    }' --jq '[.data.repository.pullRequests.nodes[] | select(.author.login == "dependabot")
      | {number, head_committed_at: .commits.nodes[0].commit.committedDate,
         comments: [.comments.nodes[] | {author: {login: .author.login}, createdAt, body: .body[0:500]}]}]' \
    >"$dir/dependabot-prs.json"
  jq --slurpfile kogut "$dir/kogut-prs.json" --slurpfile dependabot "$dir/dependabot-prs.json" \
    'map(. as $pr | . + ([$kogut[0][], $dependabot[0][] | select(.number == $pr.number)][0] // {}))' \
    "$dir/prs.json" >"$dir/prs-merged.json" && mv "$dir/prs-merged.json" "$dir/prs.json"

  gh api "repos/$full/actions/workflows?per_page=100" \
    --jq '[.workflows[] | {id, name, path, state}]' >"$dir/workflows.json"

  # Runs on the default branch only: a red PR is the PR's business, a red main
  # is the repository's. Each workflow also records whether it can be started
  # by hand, read from its file on the default branch.
  mkdir -p "$dir/dispatch"
  local path
  while read -r id path; do
    gh api "repos/$full/actions/workflows/$id/runs?branch=$branch&per_page=$window&exclude_pull_requests=true" \
      --jq "{\"$id\": [.workflow_runs[] | {id, event, status, conclusion, created_at, run_attempt, head_sha,
              triggered_by: .triggering_actor.login, url: .html_url}]}" \
      </dev/null >"$dir/runs/$id.json"
    if gh api -H 'Accept: application/vnd.github.raw' "repos/$full/contents/$path?ref=$branch" </dev/null 2>/dev/null |
      grep -Eq '^[^#]*workflow_dispatch'; then
      echo "{\"$id\": true}" >"$dir/dispatch/$id.json"
    else
      echo "{\"$id\": false}" >"$dir/dispatch/$id.json"
    fi
  done < <(jq -r '.[] | select(.state == "active") | "\(.id) \(.path)"' "$dir/workflows.json")
  find "$dir/runs" -name '*.json' -exec cat {} + | jq -s 'add // {}' >"$dir/runs.json"
  find "$dir/dispatch" -name '*.json' -exec cat {} + | jq -s 'add // {}' >"$dir/dispatch.json"
  jq --slurpfile d "$dir/dispatch.json" 'map(. + {dispatchable: ($d[0][.id | tostring] // false)})' \
    "$dir/workflows.json" >"$dir/workflows.tmp" && mv "$dir/workflows.tmp" "$dir/workflows.json"

  # Required checks come from classic branch protection and from rulesets; the
  # rules endpoint returns only the rulesets that actually apply to the branch.
  # Classic protection answers 404 for a branch without it, so its failure means
  # nothing. The rules endpoint answers for every branch, so its failure is a
  # failed read: the merge gate still sees no required checks and blocks, but it
  # must not be reported as a gap.
  local rules required_unread=false
  if ! rules="$(gh api "repos/$full/rules/branches/$branch" \
    --jq '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]' 2>/dev/null)"; then
    rules='[]'
    required_unread=true
  fi
  {
    api_or '[]' "repos/$full/branches/$branch/protection/required_status_checks" --jq '[.checks[].context]'
    printf '%s\n' "$rules"
  } | jq -s 'add | unique' >"$dir/required.json"

  # A repository can have more than one page of alerts. --jq runs once per
  # page, so it emits single alerts and jq -s gathers them.
  local alerts
  if alerts="$(gh api --paginate "repos/$full/dependabot/alerts?state=open&per_page=100" \
    --jq '.[] | {number, severity: .security_advisory.severity, package: .dependency.package.name,
            summary: .security_advisory.summary,
            patched: .security_vulnerability.first_patched_version.identifier,
            vulnerable: .security_vulnerability.vulnerable_version_range, url: .html_url,
            manifest: .dependency.manifest_path}' \
    2>"$dir/alerts.err")"; then
    jq -s '{status: "ok", items: .}' <<<"$alerts" >"$dir/alerts.json"
  elif grep -q 'disabled' "$dir/alerts.err"; then
    echo '{"status": "disabled", "items": []}' >"$dir/alerts.json"
  else
    echo '{"status": "unavailable", "items": []}' >"$dir/alerts.json"
  fi

  # Every branch, with its tip and the PRs that had it as their head, newest
  # first, which is what the pruning rule in signals.jq reads. Paginated, so a
  # repository with more than 100 branches is read in full, and about 2,200
  # nodes a page against GitHub's limit of 500,000. A branch with more than 20
  # PRs may lose its older ones, and without a match it stays. A failure leaves
  # the status unavailable, and then nothing counts as prunable.
  local branches
  # shellcheck disable=SC2016 # these are GraphQL variables
  if branches="$(gh api graphql --paginate -F owner="$owner" -F name="$repo" -f query='
    query($owner: String!, $name: String!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        refs(refPrefix: "refs/heads/", first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            name
            branchProtectionRule { id }
            rules(first: 1) { totalCount }
            target { ... on Commit { oid committedDate } }
            associatedPullRequests(first: 20, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes { number state headRefOid baseRefName isCrossRepository }
            }
          }
        }
      }
    }' --jq '.data.repository.refs.nodes[] | {name,
        protected: (.branchProtectionRule != null or .rules.totalCount > 0),
        tip: .target.oid, tip_at: .target.committedDate,
        prs: [.associatedPullRequests.nodes[] | {number, state, head: .headRefOid, base: .baseRefName, cross: .isCrossRepository}]}' \
    2>/dev/null)"; then
    jq -s '{status: "ok", items: .}' <<<"$branches" >"$dir/branches.json"
  else
    echo '{"status": "unavailable", "items": []}' >"$dir/branches.json"
  fi

  # Tasks: open issues labelled kogut-task, with who added the label (only the
  # owner can hand kogut work) and their comments, which show whether kogut
  # has answered.
  gh issue list -R "$full" --state open --label kogut-task --limit 20 \
    --json number,title,body,author,url,comments >"$dir/tasks.json"
  local n
  for n in $(jq -r '.[].number' "$dir/tasks.json"); do
    gh api "repos/$full/issues/$n/events?per_page=100" \
      --jq '[.[] | select(.event == "labeled" and .label.name == "kogut-task") | {actor: .actor.login, at: .created_at}]' \
      >"$dir/task-$n.json"
    jq --argjson n "$n" --slurpfile labeled "$dir/task-$n.json" \
      'map(if .number == $n then . + {labeled: $labeled[0]} else . end)' \
      "$dir/tasks.json" >"$dir/tasks.tmp" && mv "$dir/tasks.tmp" "$dir/tasks.json"
  done

  # kogut's own open issues: it takes some of them on as tasks without a label.
  gh issue list -R "$full" --state open --label kogut --author "app/$(kogut_app_slug)" --limit 50 \
    --json number,title,body,author,url,comments >"$dir/kogut-issues.json"

  # A failed read says nothing about the file, so it stays null rather than
  # passing for a missing one, which would file a false hygiene issue.
  local dependabot_config=false config_file config_status
  for config_file in .github/dependabot.yml .github/dependabot.yaml; do
    config_status=0
    branch_file "$full" "$branch" "$config_file" "$dir/file.err" >/dev/null || config_status=$?
    if [ "$config_status" -eq 0 ]; then
      dependabot_config=true
      break
    elif [ "$config_status" -ne 1 ]; then
      dependabot_config=null
    fi
  done

  # The Node pin on the default branch and the range the project declares. The
  # rules about them are in signals.jq, which also needs to know a read failed:
  # that says nothing about the pin, so it must not close an issue.
  local pin="" pin_file="" engines="" read_error=false file content status
  for file in .nvmrc .node-version; do
    status=0
    content="$(branch_file "$full" "$branch" "$file" "$dir/file.err")" || status=$?
    if [ "$status" -eq 0 ]; then
      pin_file="$file"
      pin="$(awk '{ sub(/\r$/, "") } NF && $1 !~ /^#/ { print substr($1, 1, 40); exit }' <<<"$content")"
      break
    elif [ "$status" -ne 1 ]; then
      read_error=true
      break
    fi
  done
  status=0
  content="$(branch_file "$full" "$branch" package.json "$dir/file.err")" || status=$?
  if [ "$status" -eq 0 ]; then
    engines="$(jq -r '.engines.node? // empty | tostring' <<<"$content" 2>/dev/null)" || engines=""
  elif [ "$status" -ne 1 ]; then
    read_error=true
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
    --slurpfile branches "$dir/branches.json" \
    --slurpfile tasks "$dir/tasks.json" \
    --slurpfile kogut_issues "$dir/kogut-issues.json" \
    --argjson last_commit "$last_commit" \
    --argjson dependabot_config "$dependabot_config" \
    --argjson required_unread "$required_unread" \
    --argjson local_clone "$local_clone" \
    --arg pin "$pin" \
    --arg pin_file "$pin_file" \
    --arg engines "$engines" \
    --argjson read_error "$read_error" \
    '{
      name: $name,
      repo: ($repo[0] | {default_branch, pushed_at, html_url, allow_auto_merge, delete_branch_on_merge}
        + {last_commit_at: $last_commit.date, head_sha: $last_commit.sha}),
      prs: $prs[0],
      workflows: $workflows[0],
      runs: $runs[0],
      required_checks: $required[0],
      required_checks_unread: $required_unread,
      alerts: $alerts[0],
      branches: $branches[0],
      tasks: $tasks[0],
      kogut_issues: $kogut_issues[0],
      dependabot_config: $dependabot_config,
      local_clone: {path: $path, present: $local_clone},
      runtime: {
        file: (if $pin_file == "" then null else $pin_file end),
        pin: (if $pin == "" then null else $pin end),
        engines: (if $engines == "" then null else $engines end),
        read_error: $read_error
      }
    }'
}

# Node's release schedule, once per run. null when it cannot be read, and then
# signals.jq judges no pin.
node_schedule="$(api_or null -H 'Accept: application/vnd.github.raw' repos/nodejs/Release/contents/schedule.json)"
jq -e 'type == "object"' <<<"$node_schedule" >/dev/null 2>&1 || node_schedule=null

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
  jq -s --arg owner "$owner" --slurpfile config "$KOGUT_CONFIG" --argjson schedule "$node_schedule" \
    '{generated_at: (now | todate), owner: $owner, app: $config[0].app.slug, policy: $config[0].policy,
      node_schedule: $schedule, repos: .}' >"$state"

jq -c -f "$KOGUT_ROOT/scripts/signals.jq" "$state"
