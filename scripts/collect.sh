#!/usr/bin/env bash
# Collects the maintenance state of the repositories in kogut.config.json.
#
#   ./scripts/collect.sh [repo ...]
#
# Writes the raw snapshot to .kogut/state.json, or to $KOGUT_STATE when set, and
# prints the signals digest computed from it by signals.jq: per repository, only
# what needs attention. The digest is compact JSON, so it fits in one read; pipe
# it to jq to browse.
# Read-only — nothing on GitHub is changed. Besides GitHub it reads only the npm
# registry, for the dates of the releases kogut's own PRs newly lock.
#
# It reads with the owner's gh login, or with policy.read_as "app" with a
# read-only token of the App per repository. What that token may not read is
# recorded as unreadable, the same as a failed read, and never read as the owner.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

owner="$(kogut_owner)"
window="$(kogut_policy run_window)"
kogut_read_as >/dev/null

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

# Why the latest run of a red workflow failed, as {kind, signature}. A finished
# run's text never changes, so the answer is kept per run attempt and per version
# of the table and of the script that picks the jobs it reads: a merge collects
# once per PR and must not download logs each time.
causes_cache="$KOGUT_ROOT/.kogut/causes"
mkdir -p "$causes_cache"
find "$causes_cache" -type f -mtime +30 -delete 2>/dev/null || true
causes_table="$(cat "$KOGUT_ROOT/scripts/causes.jq" "$KOGUT_ROOT/scripts/run-cause.sh" | cksum | awk '{ print $1 }')"
run_cause() {
  local cached="$causes_cache/$1-$2-$3-$causes_table.json" out="" status=0
  if [ -s "$cached" ]; then
    cat "$cached"
    return
  fi
  out="$("$KOGUT_ROOT/scripts/run-cause.sh" "$1" "$2" 2>/dev/null </dev/null)" || status=$?
  if ! jq -e 'type == "object" and has("kind")' <<<"$out" >/dev/null 2>&1; then
    echo '{"kind": "unknown", "signature": null}'
    return
  fi
  [ "$status" -ne 0 ] || printf '%s\n' "$out" >"$cached"
  printf '%s\n' "$out"
}

# What one of kogut's PRs newly locks, which the cooldown on kogut's PRs in
# signals.jq reads: each lockfile the PR changes, read at its head and at the tip
# of its base, and releases.sh's answer on the releases only the head locks. A
# lockfile the base does not have locks nothing there. A lockfile kogut does not
# read, or a read that fails, goes into unread, which holds the PR. npm's
# answers are shared by the whole run. Prints {lockfiles, count, youngest,
# recent, unread}.
export KOGUT_NPM_CACHE="$tmp/npm"
cooldown="$(kogut_policy cooldown_days)"
pr_releases() {
  local full="$1" n="$2" base="$3" head="$4" work="$5" files f name side ref i=0 published
  mkdir -p "$work"
  : >"$work/new"
  : >"$work/unread"
  : >"$work/lockfiles"
  if ! [[ "$base" =~ ^[0-9a-f]{40}$ && "$head" =~ ^[0-9a-f]{40}$ ]]; then
    echo "the PR's base or head commit is unknown" >>"$work/unread"
    files=""
  elif ! files="$(gh api --paginate "repos/$full/pulls/$n/files?per_page=100" \
    --jq '.[] | select(.status != "removed") | .filename' 2>/dev/null)"; then
    echo "the files the PR changes could not be read" >>"$work/unread"
    files=""
  fi
  while IFS= read -r f; do
    name="${f##*/}"
    case "$name" in
      package-lock.json | npm-shrinkwrap.json | pnpm-lock.yaml) ;;
      *.lock | *.lockb | *.lockfile | *-lock.json | *-lock.yaml | *.lock.json | go.sum)
        echo "$f" >>"$work/lockfiles"
        echo "$f is a lockfile kogut does not read" >>"$work/unread"
        continue
        ;;
      *) continue ;;
    esac
    echo "$f" >>"$work/lockfiles"
    if ! [[ "$f" =~ ^[A-Za-z0-9._/@-]+$ ]]; then
      echo "$f is a path kogut does not request" >>"$work/unread"
      continue
    fi
    i=$((i + 1))
    for side in base head; do
      ref="$base"
      [ "$side" = base ] || ref="$head"
      mkdir -p "$work/$i/$side"
      if ! gh api -H 'Accept: application/vnd.github.raw+json' "repos/$full/contents/$f?ref=$ref" \
        >"$work/$i/$side/$name" 2>"$work/err"; then
        rm -f "$work/$i/$side/$name"
        if [ "$side" = head ] || ! grep -q 'HTTP 404' "$work/err"; then
          echo "$f could not be read at the $side" >>"$work/unread"
          continue 2
        fi
      fi
    done
    if ! "$KOGUT_ROOT/scripts/releases.sh" new "$work/$i/base/$name" "$work/$i/head/$name" \
      >>"$work/new" 2>"$work/err"; then
      echo "$f: $(tail -n 1 "$work/err" | sed 's/^releases: //')" >>"$work/unread"
    fi
  done <<<"$files"
  published='{"count": 0, "youngest": null, "recent": [], "unread": []}'
  if [ -s "$work/new" ] &&
    ! published="$("$KOGUT_ROOT/scripts/releases.sh" published "$cooldown" <"$work/new" 2>"$work/err")"; then
    echo "the new releases could not be dated: $(tail -n 1 "$work/err" | sed 's/^releases: //')" >>"$work/unread"
    published='{"count": 0, "youngest": null, "recent": [], "unread": []}'
  fi
  jq -n --argjson p "$published" --rawfile lockfiles "$work/lockfiles" --rawfile unread "$work/unread" \
    '{lockfiles: ($lockfiles | split("\n") | map(select(. != ""))), count: $p.count, youngest: $p.youngest,
      recent: $p.recent, unread: (($unread | split("\n") | map(select(. != ""))) + $p.unread)}'
}

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

# Raw state of one repository, as JSON on stdout. It runs in a subshell of its
# own, so a read token stays with its repository.
collect_repo() {
  local repo="$1" full="$owner/$1" dir="$tmp/$1" branch id
  mkdir -p "$dir/runs"

  kogut_read_env "$repo"
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
    --json number,commits,reviews,comments,baseRefOid,headRefOid >"$dir/kogut-prs.json"
  # What each of them newly locks, as pr_releases above reads it.
  mkdir -p "$dir/releases"
  local pr_n pr_base pr_head
  while read -r pr_n pr_base pr_head; do
    pr_releases "$full" "$pr_n" "$pr_base" "$pr_head" "$dir/releases/$pr_n" </dev/null |
      jq -c --arg n "$pr_n" '{($n): .}' >"$dir/releases/$pr_n.json" || rm -f "$dir/releases/$pr_n.json"
  done < <(jq -r '.[] | "\(.number) \(.baseRefOid) \(.headRefOid)"' "$dir/kogut-prs.json")
  find "$dir/releases" -maxdepth 1 -name '*.json' -exec cat {} + | jq -s 'add // {}' >"$dir/releases.json"
  jq --slurpfile r "$dir/releases.json" 'map(. + {new_releases: $r[0][.number | tostring]})' \
    "$dir/kogut-prs.json" >"$dir/kogut-prs.tmp" && mv "$dir/kogut-prs.tmp" "$dir/kogut-prs.json"

  # Dependabot's PRs carry the date of their head commit and their latest
  # comments, where Dependabot says why it cannot rebase and where kogut's own
  # commands show. Asking for the last few of each keeps the query small. The head
  # commit's message and authors are what the auto-merge rule reads.
  # shellcheck disable=SC2016 # $owner and $name are GraphQL variables
  api_or '[]' graphql -F owner="$owner" -F name="$repo" -f query='
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        pullRequests(states: OPEN, first: 100) {
          nodes {
            number
            author { login }
            commits(last: 1) { nodes { commit { committedDate message authors(first: 5) { nodes { user { login } } } } } }
            comments(last: 10) { nodes { author { login } createdAt body } }
          }
        }
      }
    }' --jq '[.data.repository.pullRequests.nodes[] | select(.author.login == "dependabot")
      | {number, head_committed_at: .commits.nodes[0].commit.committedDate,
         head_message: .commits.nodes[0].commit.message,
         head_authors: [.commits.nodes[0].commit.authors.nodes[]? | .user.login],
         comments: [.comments.nodes[] | {author: {login: .author.login}, createdAt, body: .body[0:500]}]}]' \
    >"$dir/dependabot-prs.json"
  # A kogut PR with no answer on what it locks, after a failure or past the first
  # 10, counts as unread, so it is held rather than passed.
  jq --slurpfile kogut "$dir/kogut-prs.json" --slurpfile dependabot "$dir/dependabot-prs.json" \
    --arg app "app/$(kogut_app_slug)" \
    'map(. as $pr | . + ([$kogut[0][], $dependabot[0][] | select(.number == $pr.number)][0] // {})
      | if .author.login == $app and .new_releases == null then
          .new_releases = {lockfiles: [], count: 0, youngest: null, recent: [], unread: ["what the PR locks could not be read"]}
        else . end)' \
    "$dir/prs.json" >"$dir/prs-merged.json" && mv "$dir/prs-merged.json" "$dir/prs.json"

  gh api "repos/$full/actions/workflows?per_page=100" \
    --jq '[.workflows[] | {id, name, path, state}]' >"$dir/workflows.json"

  # Runs on the default branch only: a red PR is the PR's business, a red main
  # is the repository's. Each workflow also records, from its file on the default
  # branch, whether it can be started by hand and whether its schedule can cancel
  # a run started by hand; and, when it is red, why its latest run failed.
  mkdir -p "$dir/dispatch"
  local path text dispatchable scheduled cancels latest cause
  while read -r id path; do
    gh api "repos/$full/actions/workflows/$id/runs?branch=$branch&per_page=$window&exclude_pull_requests=true" \
      --jq "{\"$id\": [.workflow_runs[] | {id, event, status, conclusion, created_at, run_attempt, head_sha,
              triggered_by: .triggering_actor.login, url: .html_url}]}" \
      </dev/null >"$dir/runs/$id.json"
    text="$(gh api -H 'Accept: application/vnd.github.raw' "repos/$full/contents/$path?ref=$branch" </dev/null 2>/dev/null)" || text=""
    dispatchable=false scheduled=false cancels=false
    if grep -Eq '^[^#]*workflow_dispatch' <<<"$text"; then dispatchable=true; fi
    if grep -Eq '^[^#]*cron:' <<<"$text"; then scheduled=true; fi
    # An expression can turn it on as well, so only a plain false is off.
    if grep -E '^[^#]*cancel-in-progress:' <<<"$text" | grep -Evq ':[[:space:]]*false'; then cancels=true; fi
    # The same "latest" that health in signals.jq judges. Dependabot's own runs
    # are not the repository's CI, so their logs are not read.
    latest="$(jq -r '.[] | map(select(.status == "completed"
        and (.conclusion | IN("success", "failure", "timed_out", "startup_failure")))) | .[0]
      | select(. != null and .conclusion != "success") | "\(.id) \(.run_attempt // 1)"' "$dir/runs/$id.json")"
    cause=null
    case "$path" in
      dynamic/*) ;;
      *) if [ -n "$latest" ]; then cause="$(run_cause "$repo" "${latest% *}" "${latest#* }")"; fi ;;
    esac
    jq -cn --arg id "$id" --argjson dispatchable "$dispatchable" --argjson scheduled "$scheduled" \
      --argjson cancels "$cancels" --argjson cause "$cause" \
      '{($id): {dispatchable: $dispatchable, scheduled: $scheduled, cancels: $cancels, cause: $cause}}' \
      >"$dir/dispatch/$id.json"
  done < <(jq -r '.[] | select(.state == "active") | "\(.id) \(.path)"' "$dir/workflows.json")
  find "$dir/runs" -name '*.json' -exec cat {} + | jq -s 'add // {}' >"$dir/runs.json"
  find "$dir/dispatch" -name '*.json' -exec cat {} + | jq -s 'add // {}' >"$dir/dispatch.json"
  jq --slurpfile d "$dir/dispatch.json" 'map(. + ($d[0][.id | tostring] // {dispatchable: false}))' \
    "$dir/workflows.json" >"$dir/workflows.tmp" && mv "$dir/workflows.tmp" "$dir/workflows.json"

  # Required checks come from classic branch protection and from rulesets; the
  # rules endpoint returns only the rulesets that actually apply to the branch.
  # The rules endpoint answers for every branch, so its failure is a failed read:
  # the merge gate still sees no required checks and blocks, but it must not be
  # reported as a gap. Classic protection answers 404 for a branch without it,
  # which means none; any other failure, such as the App reading without
  # administration, leaves classic protection unknown, here and for the branches.
  local rules classic required_unread=false protection_unread=false
  if ! rules="$(gh api "repos/$full/rules/branches/$branch" \
    --jq '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]' 2>/dev/null)"; then
    rules='[]'
    required_unread=true
  fi
  if ! classic="$(gh api "repos/$full/branches/$branch/protection/required_status_checks" \
    --jq '[.checks[].context]' 2>"$dir/classic.err")"; then
    classic='[]'
    if ! grep -q 'HTTP 404' "$dir/classic.err"; then
      required_unread=true
      protection_unread=true
    fi
  fi
  printf '%s\n%s\n' "$classic" "$rules" | jq -s 'add | unique' >"$dir/required.json"

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

  # The repository's Actions secrets: names and dates, which is all GitHub ever
  # returns. api_or drops a partial answer and marks a failed read, so it cannot
  # pass for a repository with no secrets. --jq runs once per page.
  api_or '{"status": "unavailable", "items": []}' --paginate "repos/$full/actions/secrets?per_page=100" \
    --jq '{status: "ok", items: [.secrets[] | {name, updated_at}]}' |
    jq -s '{status: (if length > 0 and all(.[]; .status == "ok") then "ok" else "unavailable" end),
            items: (map(.items) | add // [])}' >"$dir/secrets.json"

  # Every branch, with its tip and the PRs that had it as their head, newest
  # first, which is what the pruning rule in signals.jq reads. Paginated, so a
  # repository with more than 100 branches is read in full, and about 2,200
  # nodes a page against GitHub's limit of 500,000. A branch with more than 20
  # PRs may lose its older ones, and without a match it stays. A failure leaves
  # the status unavailable, and then nothing counts as prunable. So does classic
  # protection that could not be read above: a token that may not read it can
  # get null for a branch's protection rule, and a protected branch would then
  # look free to delete.
  local branches
  # shellcheck disable=SC2016 # these are GraphQL variables
  if [ "$protection_unread" = false ] && branches="$(gh api graphql --paginate -F owner="$owner" -F name="$repo" -f query='
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

  # Features: open issues labelled kogut-feature, in a repository that takes them,
  # with who added that label and who added kogut-plan-approved. feature.jq decides.
  echo '[]' >"$dir/features.json"
  if kogut_feature_enabled "$repo"; then
    gh issue list -R "$full" --state open --label kogut-feature --limit 20 \
      --json number,title,url,comments,labels >"$dir/features.json"
    for n in $(jq -r '.[].number' "$dir/features.json"); do
      gh api --paginate "repos/$full/issues/$n/events?per_page=100" --jq '.[] | select(.event == "labeled")
          | {name: .label.name, actor: .actor.login, at: .created_at}' | jq -s . >"$dir/feature-events.json"
      # shellcheck disable=SC2016 # these are jq's variables
      jq --argjson n "$n" --slurpfile e "$dir/feature-events.json" 'map(if .number == $n then . + {
          labeled: [$e[0][] | select(.name == "kogut-feature") | {actor, at}],
          approvals: [$e[0][] | select(.name == "kogut-plan-approved") | {actor, at}]} else . end)' \
        "$dir/features.json" >"$dir/features.tmp" && mv "$dir/features.tmp" "$dir/features.json"
    done
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
    --slurpfile secrets "$dir/secrets.json" \
    --slurpfile tasks "$dir/tasks.json" \
    --slurpfile features "$dir/features.json" \
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
      secrets: $secrets[0],
      tasks: $tasks[0],
      features: $features[0],
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
# signals.jq judges no pin. It is public, so any of the repositories' read
# tokens can read it.
node_schedule="$(kogut_read_env "${repos[0]}" &&
  api_or null -H 'Accept: application/vnd.github.raw' repos/nodejs/Release/contents/schedule.json)" || node_schedule=null
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
