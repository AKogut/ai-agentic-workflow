#!/usr/bin/env bash
# Runs the policy in scripts/signals.jq against a fixed snapshot and checks
# each rule. KOGUT_NOW pins the clock, so the ages in the fixture never drift.
#
#   ./tests/run.sh
# The single-quoted strings are jq programs, and their $variables belong to jq.
# shellcheck disable=SC2016
set -euo pipefail
cd "$(dirname "$0")/.."

signals="$(KOGUT_NOW=2026-10-30T12:00:00Z jq -f scripts/signals.jq tests/fixtures/state.json)"
helpers='
  def repo($n): .repos[] | select(.name == $n);
  def pr($r; $n): repo($r) | (.dependabot_prs + .other_prs)[] | select(.number == $n);
  def pr_k($r; $n): repo($r) | .kogut_prs[] | select(.number == $n);
  def task($r; $n): repo($r) | .tasks[] | select(.number == $n);
'

passed=0
failed=0
# check <name> <jq program> [input]; the input defaults to the signals digest.
check() {
  if jq -e "$helpers $2" <<<"${3:-$signals}" >/dev/null; then
    echo "ok    $1"
    passed=$((passed + 1))
  else
    echo "FAIL  $1"
    failed=$((failed + 1))
  fi
}

echo "merge gate"
check "a green patch past the cooldown is ready to merge" \
  'pr("alpha"; 1) | .ready_to_merge and .blockers == []'
check "a PR younger than the cooldown is held back" \
  'pr("alpha"; 2) | (.ready_to_merge | not) and .blockers == ["younger than the 3-day cooldown"]'
check "a branch run waits for the cooldown, unless the PR fixes a high alert" \
  '[pr("alpha"; 1), pr("alpha"; 2), pr("delta"; 19), pr("delta"; 21) | .in_cooldown] == [false, true, false, true]'
check "a Dependabot PR names its branch, for a run on it" \
  'pr("alpha"; 2) | .branch == "dependabot/npm_and_yarn/opentelemetry/core-3.0.0"'
check "red checks block the merge" \
  'pr("alpha"; 3) | .checks == "red" and .blockers == ["checks are red"]'
check "a required check that never ran blocks a green PR" \
  'pr("alpha"; 4) | .checks == "green" and .blockers == ["required check '"'ci'"' did not run"]'
check "a check still running leaves the PR pending" \
  'pr("alpha"; 6) | .checks == "pending" and (.ready_to_merge | not)'
check "without required checks nothing is ever ready" \
  'pr("beta"; 7) | .checks == "green" and .blockers == ["no required checks on the default branch"]'
check "a green PR behind the default branch is held back" \
  'pr("delta"; 18) | .checks == "green" and (.ready_to_merge | not) and .blockers
     == ["behind the default branch: the ruleset wants it up to date, and Dependabot rebases only on conflicts"]'

echo
echo "security fixes and the cooldown"
check "a young PR that fixes a high alert skips the cooldown" \
  'pr("delta"; 19) | .age_days < 3 and .ready_to_merge and .blockers == []
     and .directory == "/app/gateway" and .fixes == [{package: "undici", severity: "high", count: 1}]'
check "an alert in another directory is not fixed by the PR" \
  'pr("delta"; 20) | .directory == "/" and .fixes == [] and .blockers == ["younger than the 3-day cooldown"]'
check "a fix for a medium alert still waits, and versions compare by number" \
  'pr("delta"; 21) | .fixes == [{package: "qs", severity: "medium", count: 1}]
     and .blockers == ["younger than the 3-day cooldown"]'
check "each update is matched against the alerts on its own version line" \
  'pr("delta"; 22) | .fixes == [{package: "brace-expansion", severity: "high", count: 2}] and .ready_to_merge'
check "a pre-release still inside the range, or an alert without a range, fixes nothing" \
  '[pr("delta"; 23, 25) | .fixes == [] and .blockers == ["younger than the 3-day cooldown"]] == [true, true]'
check "a group names its one directory in the body, and across several it has none" \
  '[pr("delta"; 26, 24) | .directory] == ["/app", null]
     and (pr("delta"; 26) | .ready_to_merge) and (pr("delta"; 24) | .fixes == [] and (.ready_to_merge | not))'
check "a group's fixes are read from its table, past the quoted blocks" \
  'pr("delta"; 26) | .fixes == [{package: "ms", severity: "high", count: 1}]'
check "an update claimed in quoted release notes fixes nothing" \
  'pr("delta"; 27) | (.updates | map(.package)) == ["tar"] and .fixes == []
     and .blockers == ["younger than the 3-day cooldown"]'
check "without cooldown_skip_severity every PR waits the cooldown" \
  'pr("delta"; 19) | .fixes != [] and .blockers == ["younger than the 3-day cooldown"]' \
  "$(jq '.policy |= del(.cooldown_skip_severity)' tests/fixtures/state.json |
    KOGUT_NOW=2026-10-30T12:00:00Z jq -f scripts/signals.jq)"

echo
echo "commands to Dependabot"
check "a PR behind the default branch asks for a rebase" \
  'pr("epsilon"; 60) | .command == {name: "rebase", reason: "behind the default branch"}'
check "a conflict asks for a rebase once Dependabot has had a day to rebase" \
  '[pr("epsilon"; 61, 62) | .command.name] == ["rebase", null]'
check "a PR someone else edited asks to be recreated" \
  'pr("epsilon"; 63) | .command.name == "recreate" and (.dependabot_note.text | startswith("Looks like this PR has been edited"))'
check "when Dependabot says it cannot update, no command repeats it" \
  'pr("epsilon"; 64) | .command == null and (.dependabot_note.text | startswith("Dependabot cannot update"))'
check "a command goes out once per head, and comments before the head are history" \
  '(pr("epsilon"; 65) | .command == null and .asked == {command: "rebase", at: "2026-10-28T12:00:00Z"})
   and (pr("epsilon"; 66) | .command.name == "rebase" and .asked == null and .dependabot_note == null)'
check "a red PR asks for a rebase only when the base has moved since it failed" \
  '[pr("epsilon"; 67, 68) | .command.name] == ["rebase", null]'
check "a stranger cannot speak for Dependabot or for kogut" \
  'pr("epsilon"; 69) | .command.name == "rebase" and .dependabot_note == null and .asked == null'
check "Dependabot refusing the App is neither an answer about the PR nor a command that counts" \
  'pr("epsilon"; 70) | .command.name == "rebase" and .dependabot_note == null and .asked == null'

echo
echo "branches to prune"
branches="$(KOGUT_NOW=2026-10-30T12:00:00Z jq -f scripts/signals.jq tests/fixtures/branches.json)"
b_helpers='def b: .repos[0].branches; def kept($n): b.kept[] | select(.name == $n);'
b_check() { check "$1" "$b_helpers $2" "$branches"; }
b_check "a branch whose tip is the head of a merged PR can go, and says which" \
  'b.prunable[] | select(.name == "merged") == {name: "merged", tip: "b1", pr: 11, merged_into: "main"}'
b_check "a reused name matches the merged PR with its tip, not an older one" \
  'b.prunable[] | select(.name == "reused") | .pr == 13'
b_check "only those two are prunable" \
  '[b.prunable[].name] == ["merged", "reused"]'
b_check "every branch lands in exactly one list" \
  '(b.prunable | length) + (b.kept | length) == 15 and b.status == "ok"'
b_check "the default branch stays, even at the head of a merged PR" 'kept("main").kind == "default"'
b_check "a protected branch stays" 'kept("protected").kind == "protected"'
b_check "a merge into another branch keeps it: that work may never land" \
  'kept("merged-elsewhere") | .kind == "merged-elsewhere" and (.reason | contains("into feature/stack"))'
b_check "commits after the merge keep a branch" \
  'kept("later-commits") | .kind == "later-commits" and (.reason | contains("#14"))'
b_check "a branch with no PR stays, such as flakemetry docs-snapshots" \
  '(kept("no-pr").kind == "no-pr") and (kept("docs-snapshots").kind == "no-pr")'
b_check "a PR closed without merging keeps its branch" 'kept("closed").kind == "not-merged"'
b_check "an open PR with it as head keeps a merged branch, from either list" \
  '(kept("open-head").reason == "head of open PR #2") and (kept("open-head-unlisted").reason == "head of open PR #19")'
b_check "an open PR with it as base keeps a merged branch" 'kept("open-base").reason == "base of open PR #3"'
b_check "a merge from a fork does not count" 'kept("fork-merged").kind != null and ([b.prunable[].name] | index("fork-merged") == null)'
b_check "a branch without a readable tip stays" 'kept("no-tip").kind != null'
b_check "an open Dependabot branch stays" 'kept("dependabot/npm_and_yarn/x-1.0.1").reason == "head of open PR #1"'
over_limit="$(jq '.repos[0].prs += [range(0; 100) | {number: (1000 + .), title: "x", author: {login: "example"}, isDraft: false, createdAt: "2026-10-20T12:00:00Z", statusCheckRollup: [], headRefName: "h\(.)", baseRefName: "main"}]' tests/fixtures/branches.json |
  KOGUT_NOW=2026-10-30T12:00:00Z jq -f scripts/signals.jq)"
check "over 100 open PRs, nothing is prunable" \
  '.repos[0].branches | .prunable == [] and (.kept[] | select(.name == "merged") | .kind == "unread")' "$over_limit"
check "branches that could not be read leave nothing prunable" \
  '.repos[0].branches == {status: "unavailable", prunable: [], kept: []}' \
  "$(jq '.repos[0].branches = {status: "unavailable", items: []}' tests/fixtures/branches.json | KOGUT_NOW=2026-10-30T12:00:00Z jq -f scripts/signals.jq)"
check "a snapshot without branches leaves nothing prunable" \
  '.repos[0].branches == {status: "unavailable", prunable: [], kept: []}' \
  "$(jq 'del(.repos[0].branches)' tests/fixtures/branches.json | KOGUT_NOW=2026-10-30T12:00:00Z jq -f scripts/signals.jq)"
b_digest="$(jq -c -f scripts/digest.jq <<<"$branches")"
check "the digest counts prunable branches" \
  '.[0].text | contains("**Merged branches to prune:** 2")' "$b_digest"
quiet_with_branches="$(jq -cn '{repos: [{name: "r", url: "https://example/r", ci_failing: [], dependabot_prs: [], kogut_prs: [], tasks: [], other_prs: [], workflows_disabled: [], hygiene_issues: [], branches: {status: "ok", prunable: [{name: "x"}], kept: []}}]}' | jq -c -f scripts/digest.jq)"
check "prunable branches do not change the colour or ask for anything" \
  '.[0] | .status == "green" and (.text | contains("Nothing needs you.") and contains("**Merged branches to prune:** 1"))' "$quiet_with_branches"

echo
echo "version bumps"
check "patch, minor and major are read from the title" \
  '[pr("alpha"; 1, 4, 2) | .bump.semver] == ["patch", "minor", "major"]'
check "a group PR carries no single version" \
  'pr("alpha"; 3) | .bump == null'
check "a capitalised Bump with a directory suffix is read" \
  'pr("delta"; 15) | .bump == {package: "body-parser", from: "2.3.0", to: "2.4.0", semver: "minor"}'
check "below 1.0 the first non-zero part is the major" \
  '[pr("delta"; 14) | .semver] + [pr("delta"; 12) | .updates[0].semver] == ["major", "major"]'
check "a patch below 1.0 stays a patch" \
  'pr("delta"; 13) | .updates[0] | .semver == "patch" and .package == "tsdown"'
check "a group PR lists the updates from its body, not from quoted release notes" \
  'pr("delta"; 12) | .updates | map(.package)
     == ["@opentelemetry/exporter-trace-otlp-http", "next", "typescript-eslint"]'
check "an update named only in a group's table still counts" \
  'pr("delta"; 26) | (.updates | map(.package)) == ["left-pad", "ms", "sharp"] and .semver == "major"'
check "a group PR is rated by its riskiest update" \
  '[pr("delta"; 12, 13) | .semver] == ["major", "patch"]'
check "a title without versions falls back to the body" \
  'pr("delta"; 16) | .bump == null and .semver == "patch" and .ready_to_merge'
check "a PR whose versions cannot be read is never ready" \
  'pr("delta"; 17) | .semver == null and .blockers == ["no versions in the title or the body"]'

echo
echo "majors split across PRs"
check "PRs that take one npm scope to a new major point at each other" \
  '[pr("delta"; 11, 12) | .belongs_with] == [[12], [11]]'
check "neither part of a split major is ready on its own" \
  'pr("delta"; 11) | (.ready_to_merge | not)
     and .blockers == ["major split across PRs: take it together with #12"]'
check "a lone major and green patches are not held back" \
  '[pr("delta"; 13, 14) | .belongs_with == [] and .ready_to_merge] == [true, true]'

echo
echo "pull requests"
check "the owner's PRs are kept apart and go stale after 7 days" \
  'repo("alpha") | (.other_prs | map(.number)) == [5] and (.other_prs[0] | .stale and .author == "example")'
check "commit statuses count as checks, like check runs" \
  'pr("beta"; 7) | .checks == "green"'

echo
echo "kogut's own PRs"
check "kogut's PRs are kept apart from the owner's" \
  'repo("alpha") | ([.other_prs[].number] == [5]) and ([.kogut_prs[].number] == [30, 31, 32, 33, 34])'
check "a red kogut PR needs a follow-up commit" \
  'pr_k("alpha"; 30) | .needs == "fix-ci" and .attempts == 0'
check "a review by the owner asks kogut for an answer" \
  'pr_k("alpha"; 31) | .needs == "answer" and (.feedback | map(.kind)) == ["review"]'
check "past the follow-up limit the owner takes over" \
  'pr_k("alpha"; 32) | .needs == "owner" and .attempts == 3'
check "feedback kogut already answered is settled, under its comment name" \
  'pr_k("alpha"; 33) | .needs == "review" and .feedback == []'
check "only feedback from the owner counts, and an approval asks for nothing" \
  'pr_k("alpha"; 34) | .needs == "review" and .feedback == []'

echo
echo "tasks the owner hands kogut"
check "a task the owner labelled is ready to start" \
  'task("alpha"; 40) | .needs == "start" and .labeled_by == "example"'
check "a label from anyone else hands kogut nothing" \
  'task("alpha"; 41) | .needs == "unauthorized"'
check "the latest label counts, and a kogut issue is known as one" \
  'task("alpha"; 45) | .needs == "start" and .finding'
check "a kogut PR that names the task carries it on" \
  'task("alpha"; 42) | .needs == "in-progress" and .prs == [30]'
check "once kogut has answered, the task waits for the owner" \
  'task("alpha"; 43) | .needs == "owner"'
check "a reply from the owner hands the task back to kogut" \
  'task("alpha"; 44) | .needs == "start"'
check "a package no Dependabot PR fixes is uncovered, worst first, even when a PR names it" \
  '(repo("alpha") | .findings[] | select(.key == "alerts") | .facts.uncovered) == ["shell-quote", "next"]'
check "only critical and high alerts make a package uncovered" \
  'repo("alpha") | .alerts.uncovered == ["next", "shell-quote"]'
# On delta: #23 stops at a pre-release still in tar's range, #16 and #22 leave one
# of brace-expansion's three ranges open, and ws's range cannot be read.
check "a PR that names a package but leaves an alert open does not cover it" \
  '(repo("delta") | .findings[] | select(.key == "alerts") | .facts.uncovered) == ["tar", "brace-expansion", "ws"]'
check "kogut takes on its own alerts issue while a package is uncovered" \
  'task("alpha"; 46) | .auto and .needs == "start" and .finding'
check "kogut takes on its own issue for a major" \
  'task("alpha"; 48) | .auto and .needs == "start"'
check "kogut leaves its other issues and gone findings alone" \
  '(repo("alpha") | [.tasks[].number] | index(47) == null) and (repo("beta") | .tasks == [])'
check "a marker copied into an issue by someone else makes no task" \
  'repo("alpha") | [.tasks[].number] | index(49) == null'
# delta with only the alerts its PRs fix, then with some of those PRs taken away.
delta_only='(.repos[] | select(.name == "delta") | .alerts.items) |= map(select(.package | IN("vite", "undici", "ms")))'
fixed_only="$(jq "$delta_only" tests/fixtures/state.json | KOGUT_NOW=2026-10-30T12:00:00Z jq -f scripts/signals.jq)"
without_19="$(jq "$delta_only"' | (.repos[] | select(.name == "delta") | .prs) |= map(select(.number != 19))' tests/fixtures/state.json |
  KOGUT_NOW=2026-10-30T12:00:00Z jq -f scripts/signals.jq)"
without_19_24="$(jq "$delta_only"' | (.repos[] | select(.name == "delta") | .prs) |= map(select(.number | IN(19, 24) | not))' tests/fixtures/state.json |
  KOGUT_NOW=2026-10-30T12:00:00Z jq -f scripts/signals.jq)"
check "alerts the PRs fix are covered, and kogut leaves their issue alone" \
  'repo("delta") | .alerts.uncovered == [] and .tasks == []
   and (.findings[] | select(.key == "alerts") | .facts.uncovered) == []' "$fixed_only"
check "a group across several directories covers what it moves, though fixes[] cannot claim it" \
  'repo("delta") | .alerts.uncovered == [] and (.dependabot_prs[] | select(.number == 24) | .fixes) == []' "$without_19"
check "the same update in another directory does not cover an alert" \
  'repo("delta") | .alerts.uncovered == ["undici"]' "$without_19_24"

echo
echo "workflows on the default branch"
check "consecutive failures form a streak, with the last success" \
  'repo("alpha") | .ci_failing == [{id: 1, name: "CI", path: ".github/workflows/ci.yml", action: null, failing_streak: 2, of_runs: 4,
     last_success_at: "2026-10-27T09:00:00Z",
     latest_run: {id: 11, event: "push", conclusion: "failure", created_at: "2026-10-29T09:00:00Z",
                  url: "https://github.com/example/alpha/actions/runs/11"}}]'
check "a failure followed by a pass is flaky, not failing" \
  'repo("alpha") | .ci_flaky == [{name: "Nightly", path: ".github/workflows/nightly.yml", failures: 1, of_runs: 3}]'
check "cancelled runs say nothing about health" \
  'repo("alpha") | [.ci_failing[], .ci_flaky[]] | map(.name) | index("Report") == null'
check "disabled workflows are listed with the reason" \
  'repo("alpha") | .workflows_disabled == [{id: 4, name: "Old nightly", path: ".github/workflows/old-nightly.yml",
     state: "disabled_inactivity", action: {name: "enable", reason: "GitHub disabled it after 60 days without activity"}}]'

# A red or disabled workflow in a fixture repository, by file name.
wf() { echo "(repo(\"$1\") | (.ci_failing + .workflows_disabled)[] | select(.path == \".github/workflows/$2.yml\"))"; }

echo
echo "what kogut may run"
check "a failed run on the current head is retried once" \
  "[$(wf epsilon flaky), $(wf epsilon retried) | .action.name] == [\"rerun\", null]"
check "a failure that keeps coming back is not retried" \
  "$(wf epsilon persistent) | .failing_streak == 3 and .action == null"
check "a red run on an older commit runs again at the head, if the workflow can be started by hand" \
  "[$(wf epsilon stale), $(wf epsilon stale-schedule) | .action.name] == [\"dispatch\", null]"
check "a run too old for GitHub to retry runs again at the head instead" \
  "$(wf epsilon old-head) | .action == {name: \"dispatch\", reason: \"the last run is too old for GitHub to retry\"}"
check "kogut starts a workflow once per head, and nothing while a run is going" \
  "[$(wf epsilon dispatched), $(wf epsilon running) | .action] == [null, null]"
check "a workflow the owner disabled stays disabled" \
  "$(wf epsilon manual-off) | .state == \"disabled_manually\" and .action == null"

echo
echo "hygiene"
check "a well-kept repository has no hygiene issues" \
  'repo("alpha") | .hygiene_issues == []'
check "every gap is reported" \
  'repo("beta") | .hygiene_issues as $issues
   | ["no required status checks", "auto-merge is disabled", "no .github/dependabot.yml",
      "Dependabot alerts are disabled", "no commits on main for 50 days", "no local clone", "merged branches are not deleted"]
   | all(. as $gap | any($issues[]; startswith($gap)))'
check "idleness counts commits on the default branch, not pushes to other branches" \
  'repo("beta") | .hygiene.days_since_commit == 50'
check "a repository that failed to collect keeps its error and nothing else" \
  'repo("gamma") == {name: "gamma", error: "gh: Not Found (HTTP 404)"}'

echo
echo "alerts"
check "alerts are counted by severity" \
  'repo("alpha") | .alerts | .total == 4 and .by_severity == {critical: 1, high: 1, medium: 1, low: 1}'
check "alerts are grouped per package, worst first" \
  'repo("alpha") | .alerts.packages | map(.package) == ["shell-quote", "next", "extract-zip"]'
check "a package carries its worst alert, its count and every fixed version" \
  'repo("alpha") | .alerts.packages[1] == {package: "next", severity: "high", count: 2,
     patched: ["16.3.8", "16.3.9"], url: "https://github.com/example/alpha/security/dependabot/1"}'
check "an alert without a fix leaves the fixed versions empty" \
  'repo("alpha") | .alerts.packages[2].patched == []'
check "a repository without alerts has an empty summary" \
  'repo("beta") | .alerts == {total: 0, by_severity: {}, packages: [], uncovered: []}'

echo
echo "findings tracked as issues"
check "a workflow red for two runs is a finding with a stable key" \
  'repo("alpha") | .findings[] | select(.key == "ci:.github/workflows/ci.yml")
   | .auto and .facts.failing_streak == 2 and .slug == "ci-github-workflows-ci-yml"'
check "a flaky workflow is not a finding" \
  'repo("alpha") | [.findings[] | select(.kind == "ci") | .facts.workflow] == ["CI"]'
check "a single red run becomes a finding only once it is a day old" \
  '(repo("delta") | .ci_failing | length) == 2
   and (repo("delta") | [.findings[] | select(.kind == "ci") | .facts.workflow]) == ["Report"]'
check "a red Dependabot Updates run is reported but is not a finding" \
  '(repo("delta") | any(.ci_failing[]; .path == "dynamic/dependabot/dependabot-updates"))
   and (repo("delta") | [.findings[] | select(.kind == "ci")] == [])' \
  "$(jq '(.repos[] | select(.name == "delta") | .workflows[] | select(.name == "Report") | .path) = "dynamic/dependabot/dependabot-updates"' tests/fixtures/state.json |
    KOGUT_NOW=2026-10-30T12:00:00Z jq -f scripts/signals.jq)"
check "a disabled workflow is a finding" \
  'repo("alpha") | any(.findings[]; .key == "workflow-disabled:.github/workflows/old-nightly.yml" and .facts.state == "disabled_inactivity")'
check "critical and high alerts are one finding, worst first" \
  'repo("alpha") | .findings[] | select(.key == "alerts") | .facts.packages | map(.package) == ["shell-quote", "next"]'
check "hygiene gaps are one finding, and a well-kept repository has none" \
  '(repo("beta") | any(.findings[]; .key == "hygiene")) and (repo("alpha") | all(.findings[]; .key != "hygiene"))'
check "majors are grouped per npm scope and wait for the model" \
  'repo("delta") | .findings[] | select(.key == "major:@opentelemetry/*")
   | (.auto | not) and (.facts.prs | map(.number)) == [11, 12] and .slug == "major-at-opentelemetry"'
check "an unscoped major is a finding of its own, with its versions" \
  'repo("delta") | .findings[] | select(.key == "major:left-pad") | .facts.prs[0].versions == ["left-pad 0.0.3 → 0.0.4"]'

# The issue policy in scripts/issues.jq, run on a fixture repository's findings
# with the given open issues and diagnoses.
plan() {
  jq -c -n -L scripts --argjson d "$(jq -c --arg r "$1" '.repos[] | select(.name == $r)' <<<"$signals")" \
    --argjson issues "$2" --argjson texts "$3" \
    'include "issues"; plan($d; $issues; $texts; "2026-10-30"; "https://example.com/kogut")'
}

echo
echo "issue policy"
fresh="$(plan alpha '[]' '{}')"
check "auto findings are opened, and a major without a diagnosis is not" \
  'map({action, title}) == [
     {action: "open", title: "CI: CI is failing on main"},
     {action: "open", title: "CI: Old nightly is disabled"},
     {action: "open", title: "Security: critical and high Dependabot alerts"},
     {action: "skip", title: "Major upgrade: @opentelemetry/*"}]' "$fresh"
check "a diagnosis opens the issue for a major and leads its body" \
  '.[] | select(.title == "Major upgrade: @opentelemetry/*") | .action == "open"
   and (.body | startswith("Needs a migration.\n\n<!-- kogut-facts -->"))
   and (.body | contains("- #2: @opentelemetry/core 2.12.0 → 3.0.0"))' \
  "$(plan alpha '[]' '{"major-at-opentelemetry": "Needs a migration.\n"}')"
existing="$(jq -c -n --argjson fresh "$fresh" '[
  {number: 7, title: "CI: CI is failing on main", url: "u7", key: "ci:.github/workflows/ci.yml",
   body: "Old diagnosis.\n\n<!-- kogut-facts -->\nstale facts\n<!-- kogut-finding: ci:.github/workflows/ci.yml -->"},
  {number: 8, title: "Repository hygiene gaps", url: "u8", key: "hygiene", body: "gaps"},
  ($fresh[] | select(.title | startswith("Security")) | {number: 9, title, url: "u9", key, body}),
  {number: 10, title: "Not filed by kogut", url: "u10", key: null, body: "no key"}]')"
kept="$(plan alpha "$existing" '{}')"
check "an issue gets fresh facts and keeps its diagnosis" \
  '.[] | select(.number == 7) | .action == "update"
   and (.body | startswith("Old diagnosis.\n\n<!-- kogut-facts -->"))
   and (.body | contains("Failed runs in a row on the default branch: 2 of the last 4"))' "$kept"
check "a new diagnosis replaces the old one" \
  '.[] | select(.number == 7) | (.body | startswith("New diagnosis.")) and (.body | contains("Old diagnosis") | not)' \
  "$(plan alpha "$existing" '{"ci-github-workflows-ci-yml": "New diagnosis."}')"
check "an issue that already reads right is left alone" \
  '.[] | select(.number == 9) | .action == "keep"' "$kept"
check "an issue whose finding is gone is closed, saying why" \
  '.[] | select(.number == 8) | .action == "close" and (.comment | contains("no hygiene gaps are left"))' "$kept"
check "an issue without a kogut key is never touched" \
  'all(.[]; .number != 10)' "$kept"

# The progress report in scripts/progress.jq, on a fixed set of search results.
progress="$(jq -c --arg format json -f scripts/progress.jq tests/fixtures/progress.json)"
report="$(jq -r --arg format markdown -f scripts/progress.jq tests/fixtures/progress.json)"
p_repo='def p($n): .repos[] | select(.name == $n);'

echo
echo "the Node runtime"
rt_fixture=tests/fixtures/runtime.json
rt_clock=2026-11-03T12:00:00Z
# A one-repository snapshot with the given pin and engines ("" for none).
rt_state() {
  jq -c --arg pin "$1" --arg engines "${2:-}" '.repos[0].runtime = {file: ".nvmrc",
      pin: (if $pin == "" then null else $pin end),
      engines: (if $engines == "" then null else $engines end), read_error: false}' "$rt_fixture"
}
rt_signals() { KOGUT_NOW="${1:-$rt_clock}" jq -c -f scripts/signals.jq; }
rt() { rt_state "$1" "${2:-}" | rt_signals "${3:-}"; }
# One repository per [pin, engines] row, to check a whole table at once.
rt_table() {
  jq -c --argjson rows "$1" '.repos[0] as $r
    | .repos = [$rows[] | $r + {runtime: {file: ".nvmrc", pin: .[0], engines: .[1], read_error: false}}]' "$rt_fixture" | rt_signals
}
no_runtime_finding='.repos[0] | all(.findings[]; .key != "runtime:node")'
rt_eol="$(rt 20 '>=22.18')"
rt_maintenance="$(rt 24)"
rt_outside="$(rt 22.10.0 '>=22.18')"
rt_no_schedule="$(rt_state 20 '>=22.18' | jq -c '.node_schedule = null' | rt_signals)"
rt_read_error="$(rt_state 20 '>=22.18' | jq -c '.repos[0].runtime.read_error = true' | rt_signals)"

check "a line past its end of life is a finding, and names the Active LTS" \
  '.repos[0] | (.runtime | .line == 20 and .phase == "eol" and .since == "2026-04-30" and .active_lts == 26 and .flagged)
   and (.findings[] | select(.key == "runtime:node")
     | .auto and .kind == "runtime" and .slug == "runtime-node" and .title == "Runtime: Node 20 is past its end of life")' "$rt_eol"
check "a line past its end of life is a finding even when it fits engines" \
  '.repos[0] | (.runtime | .phase == "eol" and (.conflict | not) and .flagged) and any(.findings[]; .key == "runtime:node")' "$(rt 20 '>=18')"
check "a line on maintenance is said, but is not a finding" \
  '.repos[0].runtime | .phase == "maintenance" and .since == "2026-10-20" and .active_lts == 26 and (.flagged | not)' "$rt_maintenance"
check "a line on maintenance opens no issue" "$no_runtime_finding" "$rt_maintenance"
check "the Active LTS line is not a finding" \
  '(.repos[0].runtime | .phase == "active" and .since == null and (.flagged | not))' "$(rt 26)"
check "a Current line is not a finding, and the clock decides the phase" \
  '(.repos[0].runtime | .phase == "current" and .active_lts == 24 and (.flagged | not))' "$(rt 26 '' 2026-08-01T00:00:00Z)"
check "there may be no Active LTS line for a few days" \
  '.repos[0].runtime.active_lts == null' "$(rt 24 '' 2026-10-25T00:00:00Z)"
check "a line not in the schedule or not started is unknown, and not a finding" \
  'all(.repos[]; .runtime.phase == "unknown" and (.runtime.flagged | not))' "$(rt_table '[["99",""],["27",""]]')"
check "a pin may be a full version, with a v, or an LTS codename" \
  '[.repos[].runtime.line] == [20, 20, 20, 20]' "$(rt_table '[["20",""],["20.11.1",""],["v20.11",""],["lts/iron",""]]')"
check "a pin that names no fixed line is not judged" \
  'all(.repos[]; .runtime.line == null and .runtime.phase == "unknown" and (.runtime.flagged | not))' \
  "$(rt_table '[["lts/*",""],["node",""],["stable",""],["lts/nope",""]]')"
check "a pin outside engines is a finding, even on a supported line" \
  '.repos[0] | (.runtime | .phase == "maintenance" and .conflict and .flagged)
   and (.findings[] | select(.key == "runtime:node") | .title == "Runtime: Node 22 in .nvmrc is outside engines" and .facts.conflict)' "$rt_outside"
check "a pin that fits engines is not a conflict: a bare major is the whole line" \
  'all(.repos[]; .runtime.conflict == false and .runtime.engines_readable)' \
  "$(rt_table '[["22",">=22.18"],["22","^22.22.1 || >=24"],["24","^22.22.1 || >=24"],["22.22.1","^22.22.1 || >=24"],
     ["26",">= 24"],["22.18.5","~22.18.0"],["22","~22"],["22.5.0","<=22"],["22.1.5","22.1"],["24","24.x"],["26","*"],
     ["22.1.0","=22.1.0"],["22",">=22 <24"],["22",">22.18.0 <22.19"],["lts/jod",">=22"],["v22.18.0",">=22.18"],
     ["26",">=22.18 || <20"],["22.18.0","<=22.18.0"]]')"
check "a pin outside engines is a conflict, for each kind of comparator" \
  'all(.repos[]; .runtime.conflict == true and .runtime.engines_readable)' \
  "$(rt_table '[["20",">=22.18"],["23","^22.22.1 || >=24"],["22.1.0","^22.22.1 || >=24"],["22.19.0","~22.18.0"],["26","^24"],
     ["22.0.0","<22"],["22.5.0",">22"],["22.1.9",">22.1"],["22.18.0",">22.18.0"],["24",">=22 <24"],["26","24.x"],
     ["22.2.0","22.1"],["lts/iron",">=22"],["23","<=22"],["24.0.0","~22"],["22.19.0","<=22.18.0"]]')"
check "a range kogut cannot read is never a conflict" \
  'all(.repos[]; .runtime.conflict == false and (.runtime.engines_readable | not) and (.runtime.flagged | not))' \
  "$(rt_table '[["26","22 - 24"],["26",">=22 garbage"],["26","^0.12"],["26",""],["26",">=22 ||"],["26","22.0.0-rc.1"],["26","latest"]]')"
check "engines without a pin, or a pin without engines, is no conflict" \
  'all(.repos[]; .runtime.conflict == false and (.runtime.flagged | not))' "$(rt_table '[[null,">=22.18"],["26",null]]')"
check "no pin means no finding" \
  '.repos[0] | (.runtime | .pin == null and .judged and (.flagged | not)) and all(.findings[]; .key != "runtime:node")' "$(rt '' '>=22.18')"
check "without the schedule the phase is unknown and nothing is flagged" \
  '.repos[0] | (.runtime | .phase == "unknown" and .active_lts == null and (.judged | not) and (.flagged | not))
   and all(.findings[]; .key != "runtime:node")' "$rt_no_schedule"
check "a file that could not be read flags nothing" \
  '.repos[0] | (.runtime | (.judged | not) and (.flagged | not)) and all(.findings[]; .key != "runtime:node")' "$rt_read_error"
check "a snapshot from before the runtime was collected flags nothing" \
  '.repos[0].runtime | (.judged | not) and (.flagged | not)' "$(rt_signals <"$rt_fixture")"

rt_plan() {
  jq -c -n -L scripts --argjson d "$(jq -c '.repos[0]' <<<"$1")" --argjson issues "$2" \
    'include "issues"; plan($d; $issues; {}; "2026-11-03"; "https://example.com/kogut")'
}
rt_issue='[{"number": 5, "title": "Runtime: Node 20 is past its end of life", "url": "u5", "key": "runtime:node", "body": "old"}]'
check "the issue's facts name the pin, the line, the Active LTS and engines" \
  '.[0] | .action == "open" and .key == "runtime:node" and (.body
     | contains("- Pin: `20` in `.nvmrc`\n- Node 20: past its end of life since 2026-04-30\n- Active LTS: Node 26\n- `engines.node`: `>=22.18`, which the pin does not satisfy")
       and contains("<!-- kogut-finding: runtime:node -->"))' "$(rt_plan "$rt_eol" '[]')"
check "the facts of a pin outside engines on maintenance say so" \
  '.[0].body | contains("- Pin: `22.10.0` in `.nvmrc`\n- Node 22: on maintenance since 2025-10-21")' "$(rt_plan "$rt_outside" '[]')"
check "once the pin is fine, the issue closes and says why" \
  '.[0] | .action == "close" and .number == 5 and (.comment | contains("the Node pin is no longer past its end of life or outside `engines`"))' \
  "$(rt_plan "$(rt 26 '>=22.18')" "$rt_issue")"
check "once the pin is gone, the issue closes" \
  '.[0].action == "close"' "$(rt_plan "$(rt '')" "$rt_issue")"
check "an issue stays open when the schedule could not be read" \
  '.[0] | .action == "keep" and .number == 5' "$(rt_plan "$rt_no_schedule" "$rt_issue")"
check "an issue stays open when a file could not be read" \
  '.[0] | .action == "keep" and .number == 5' "$(rt_plan "$rt_read_error" "$rt_issue")"

rt_digest() { jq -c -f scripts/digest.jq <<<"$1"; }
check "the digest mentions a line on maintenance and stays green" \
  '.[0] | .status == "green" and (.text | contains("**Node:** `24` in `.nvmrc`, on maintenance. Active LTS: 26.") and contains("Nothing needs you."))' \
  "$(rt_digest "$rt_maintenance")"
check "a line past its end of life makes the digest yellow" \
  '.[0] | .status == "yellow" and (.text | contains("**Node:** `20` in `.nvmrc`, past its end of life, outside `engines` `>=22.18`. Active LTS: 26.") and (contains("Nothing needs you.") | not))' \
  "$(rt_digest "$rt_eol")"
check "a pin outside engines makes the digest yellow" \
  '.[0] | .status == "yellow" and (.text | contains("on maintenance, outside `engines` `>=22.18`"))' "$(rt_digest "$rt_outside")"
check "a supported line, or a pin kogut could not judge, stays out of the digest" \
  'all(.[]; .status == "green" and (.text | contains("**Node") | not))' \
  "$(rt_digest "$(rt_table '[["26",null],[null,">=22.18"]]')")"
check "without the schedule the digest says nothing about the pin" \
  '.[0] | .status == "green" and (.text | contains("**Node") | not)' "$(rt_digest "$rt_no_schedule")"

echo
echo "progress report"
check "kogut's merges are the PRs the App merged" \
  "$p_repo"' p("alpha") | .kogut.merged == 1' "$progress"
check "kogut's PRs count what happened in the window" \
  "$p_repo"' p("alpha") | .kogut.prs == {opened: 3, merged: 1, closed: 1, open: 1}' "$progress"
check "issues kogut closed are kept apart from the owner's" \
  "$p_repo"' p("alpha") | .kogut.issues == {opened: 2, closed: 1, closed_by_owner: 1, open: 1}' "$progress"
check "comments count from when they were written, commands among them" \
  "$p_repo"' p("alpha") | .kogut.comments == 2 and .kogut.commands == 1' "$progress"
check "the owner's merges split into kogut's fixes, Dependabot's and their own" \
  "$p_repo"' p("alpha") | .owner | {merged, kogut_fixes, dependabot, own} == {merged: 3, kogut_fixes: 1, dependabot: 1, own: 1}' "$progress"
check "commands under the owner's login count in the window, and only whole commands from the owner" \
  "$p_repo"' p("alpha") | .owner.dependabot_commands == 2 and .links.dependabot_commands == ["o1", "o2"]' "$progress"
check "commands under the owner's login never count as kogut's" \
  "$p_repo"' p("alpha") | .kogut.comments == 2 and .kogut.commands == 1 and (.links.kogut_merged | index("o1") == null)' "$progress"
check "the report does not claim those commands for kogut, or for the owner's own hand" \
  'split("\n") | any(.[]; contains("2 commands to Dependabot went out under the owner'"'"'s login, typed by hand or sent through kogut"))' \
  "$(jq -Rs . <<<"$report")"
no_commands="$(jq 'del(.figures[0].comments[] | select(.by == "example"))' tests/fixtures/progress.json | jq -r --arg format markdown -f scripts/progress.jq)"
check "no commands, no sentence about them" \
  'contains("under the owner") | not' "$(jq -Rs . <<<"$no_commands")"
check "alerts closed in the window and open now are counted by severity" \
  "$p_repo"' p("alpha") | .alerts.fixed == {high: 1, critical: 1} and .alerts.open == {critical: 1, high: 2}' "$progress"
check "the PRs and issues behind the numbers come with their links" \
  "$p_repo"' p("alpha") | .links == {kogut_merged: ["https://github.com/example/alpha/pull/20"],
     fix_prs: ["https://github.com/example/alpha/pull/1", "https://github.com/example/alpha/pull/2", "https://github.com/example/alpha/pull/3"],
     issues: ["https://github.com/example/alpha/issues/10", "https://github.com/example/alpha/issues/11"],
     dependabot_commands: ["o1", "o2"]}' "$progress"
check "repositories kogut does not watch stay out, totals included" \
  '[.repos[].name] == ["alpha", "beta"] and .totals.owner.merged == 3 and .totals.kogut.prs.opened == 4' "$progress"
check "the report sums up the window and marks alerts it could not read" \
  'split("\n") | (.[0] == "## kogut progress, 25 Oct 2026 to 1 Nov 2026")
     and any(.[]; startswith("kogut merged 1 Dependabot PR, opened 4 fix PRs (1 merged by the owner, 1 closed unmerged, 2 open now)"))
     and any(.[]; . == "| beta | 0 | 1 (0) | 0 / 0 | 0 | n/a | n/a | 0 (0) |")' "$(jq -Rs . <<<"$report")"

echo
echo "dismissing alerts"
# The argument is a jq expression for the input, built from these alerts, and
# the variables override what is asked for. Single-quoted, so the shell leaves
# the braces alone.
dismissal() {
  jq -cn 'def alert($n; $severity; $package; $manifest):
            {number: $n, severity: $severity, package: $package, manifest: $manifest, url: "https://example/a/\($n)"};
          def items: [alert(7; "medium"; "qs"; "app/package-lock.json"), alert(3; "low"; "qs"; "app/package-lock.json"),
            alert(9; "high"; "qs"; "package-lock.json"), alert(11; "medium"; "ms"; "app/package-lock.json"),
            alert(12; "high"; "size"; "app/package-lock.json"), alert(13; "low"; "size"; "app/package-lock.json"),
            alert(14; "critical"; "bad"; "app/package-lock.json"), alert(15; "low"; "bad"; "app/package-lock.json")];
          def input: {alerts: {status: "ok", items: items}, dependabot_prs: []};
          '"${1:-input}" |
    jq -c --arg package "${package:-qs}" --arg manifest "${manifest:-app/package-lock.json}" \
      --arg reason "${reason-tolerable_risk}" --arg comment "${comment-build time only}" \
      --argjson severe "${severe:-false}" -f scripts/dismiss.jq
}
check "only that package in that manifest is dismissed, in order" \
  '.alerts == [{number: 3, severity: "low", url: "https://example/a/3"}, {number: 7, severity: "medium", url: "https://example/a/7"}]' "$(dismissal)"
check "the same package in the root manifest is its own set" \
  '[.alerts[].number] == [9]' "$(manifest=package-lock.json severe=true dismissal)"
check "a package with no open alert there is refused" \
  '.refusal == "no open alert for nope in app/package-lock.json"' "$(package=nope dismissal)"
check "a manifest with no alert for the package is refused" \
  '.refusal | startswith("no open alert")' "$(package=ms manifest=package-lock.json dismissal)"
check "a critical alert is never dismissed, whatever comes with it" \
  '.refusal | contains("a critical alert is never dismissed")' "$(package=bad severe=true dismissal)"
check "a high alert needs --severe" \
  '.refusal | endswith("pass --severe")' "$(package=size dismissal)"
check "--severe takes the package's lower alerts with the high one" \
  '[.alerts[].number] == [12, 13]' "$(package=size severe=true dismissal)"
check "--severe with no high alert is refused, so the prompt says what is there" \
  '.refusal | endswith("drop --severe")' "$(severe=true dismissal)"
check "an open Dependabot PR that fixes the package in that directory holds it" \
  '.refusal == "#5, #6 fixes qs in /app: the fix is on the way"' \
  "$(dismissal 'input + {dependabot_prs: [{number: 5, directory: "/app", fixes: [{package: "qs"}]},
                                          {number: 6, directory: "/app", fixes: [{package: "ms"}, {package: "qs"}]}]}')"
check "a PR in another directory or for another package does not" \
  '[.alerts[].number] == [3, 7]' \
  "$(dismissal 'input + {dependabot_prs: [{number: 5, directory: "/", fixes: [{package: "qs"}]},
                                          {number: 6, directory: "/app", fixes: [{package: "ms"}]},
                                          {number: 8, directory: null, fixes: []}]}')"
check "a fix for the root manifest holds the root manifest" \
  '.refusal | startswith("#5 fixes qs in /:")' \
  "$(manifest=package-lock.json severe=true dismissal 'input + {dependabot_prs: [{number: 5, directory: "/", fixes: [{package: "qs"}]}]}')"
check "only GitHub's reasons are accepted" \
  '.refusal | startswith("the reason must be one of tolerable_risk, not_used, inaccurate, no_bandwidth, fix_started")' "$(reason=because dismissal)"
check "a reason is required" \
  '.refusal | startswith("the reason must be one of")' "$(reason='' dismissal)"
check "a comment is required" \
  '.refusal | startswith("the comment is required")' "$(comment='' dismissal)"
check "blanks are not a comment" \
  '.refusal | startswith("the comment is required")' "$(comment='   ' dismissal)"
check "a comment of 280 characters passes" \
  '.alerts != null' "$(comment="$(printf 'x%.0s' $(seq 1 280))" dismissal)"
check "a comment of 281 characters does not" \
  '.refusal == "the comment has 281 characters, and GitHub takes 280"' "$(comment="$(printf 'x%.0s' $(seq 1 281))" dismissal)"
check "nothing is dismissed when the alerts could not be read" \
  '.refusal == "its alerts could not be read: unavailable"' "$(dismissal '{alerts: {status: "unavailable", items: []}}')"
check "nothing is dismissed when the repository could not be read" \
  '.refusal == "the repository could not be read: boom"' "$(dismissal '{error: "boom"}')"
check "once the critical and high alerts are gone, so is the finding its issue tracks" \
  '[.repos[] | select(.name == "alpha") | .findings[] | select(.key == "alerts")] == []' \
  "$(jq '.repos |= map(if .alerts then .alerts.items |= map(select(.severity | IN("critical", "high") | not)) else . end)' tests/fixtures/state.json |
    KOGUT_NOW=2026-10-30T12:00:00Z jq -f scripts/signals.jq)"

echo "daily digest"
# Each argument is a jq expression for the digest's repositories, built from a
# quiet repository and one PR. Single-quoted, so the shell leaves the braces alone.
digest_of() {
  jq -cn 'def quiet: {name: "r", url: "https://example/r", ci_failing: [], dependabot_prs: [], kogut_prs: [],
            tasks: [], other_prs: [], workflows_disabled: [], hygiene_issues: []};
          def one: {number: 1, url: "https://example/1", title: "chore: a title someone wrote", semver: "patch"};
          def run($path): {name: "Nightly", path: $path, failing_streak: 4, latest_run: {url: "https://example/run"}};
          {repos: ['"$1"']}' | jq -c -f scripts/digest.jq
}
check "a quiet repository is green and says so" \
  '.[0] | .status == "green" and (.text | contains("Nothing needs you."))' "$(digest_of 'quiet')"
check "PRs in cooldown alone stay green and are only counted" \
  '.[0] | .status == "green" and (.text | contains("Nothing needs you.") and contains("**In cooldown:** 1 PR"))' \
  "$(digest_of 'quiet + {dependabot_prs: [one + {ready_to_merge: false, blockers: ["younger than the 3-day cooldown"]}]}')"
check "a ready PR waits for a run, and a major says so" \
  '.[0] | .status == "yellow" and (.text | contains("**Ready to merge:** [#1](https://example/1) (major)") and (contains("Nothing needs you.") | not))' \
  "$(digest_of 'quiet + {dependabot_prs: [one + {semver: "major", ready_to_merge: true, blockers: []}]}')"
check "a PR held by more than the cooldown is stuck, with its reasons" \
  '.[0] | .status == "yellow" and (.text | contains("- [#1](https://example/1): checks are red; younger than the 3-day cooldown"))' \
  "$(digest_of 'quiet + {dependabot_prs: [one + {ready_to_merge: false, blockers: ["checks are red", "younger than the 3-day cooldown"]}]}')"
check "a red default branch is red" \
  '.[0] | .status == "red" and (.text | contains("[Nightly](https://example/run), 4 in a row"))' \
  "$(digest_of 'quiet + {ci_failing: [run(".github/workflows/n.yml")]}')"
check "a red run of Dependabot's own is not the repository's CI" \
  '.[0] | .status == "green" and (.text | contains("CI red") | not)' \
  "$(digest_of 'quiet + {ci_failing: [run("dynamic/dependabot/dependabot-updates")]}')"
check "a high alert is red, and medium alerts alone are not" \
  '.[0].status == "red" and .[1].status == "green" and (.[0].text | contains("[2 high, 1 low](https://example/r/security/dependabot)"))' \
  "$(digest_of '(quiet + {alerts: {by_severity: {low: 1, high: 2}}}), (quiet + {alerts: {by_severity: {medium: 3}}})')"
check "a stale PR of the owner's shows, and a draft is marked" \
  '.[0] | .status == "yellow" and (.text | contains("- [#1](https://example/1) (draft), 14 days old"))' \
  "$(digest_of 'quiet + {other_prs: [one + {stale: true, draft: true, age_days: 14}]}')"
check "kogut's own issues do not count as tasks waiting" \
  '.[0] | .status == "green"' "$(digest_of 'quiet + {tasks: [one + {auto: true, needs: "start"}]}')"
check "a repository that could not be read says why" \
  '.[0] | .status == "yellow" and .text == "Could not read this repository: boom"' "$(digest_of '{name: "r", error: "boom"}')"
check "no PR title reaches a channel" \
  'all(.[]; .text | contains("a title someone wrote") | not)' \
  "$(digest_of 'quiet + {dependabot_prs: [one + {ready_to_merge: true, blockers: []}, one + {ready_to_merge: false, blockers: ["checks are red"]}],
                 kogut_prs: [one + {needs: "review"}], tasks: [one + {auto: false, needs: "start"}],
                 other_prs: [one + {stale: true, draft: false, age_days: 9}]}')"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
