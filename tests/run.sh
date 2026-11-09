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
  'repo("alpha") | .ci_failing == [{id: 1, name: "CI", path: ".github/workflows/ci.yml", action: null, held: null,
     cause: {kind: "unknown", signature: null}, failing_streak: 2, of_runs: 4,
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
unread="$(jq '(.repos[] | select(.name == "alpha")) |= (.dependabot_config = null | .required_checks = [] | .required_checks_unread = true)' tests/fixtures/state.json |
  KOGUT_NOW=2026-10-30T12:00:00Z jq -f scripts/signals.jq)"
check "a file or a rule that could not be read is not reported as missing" \
  'repo("alpha") | .hygiene_issues == []' "$unread"
check "the merge gate still blocks when the required checks could not be read" \
  'pr("alpha"; 1) | (.ready_to_merge | not) and any(.blockers[]; startswith("no required checks"))' "$unread"
check "a file that is really missing is still reported" \
  'repo("beta") | any(.hygiene_issues[]; . == "no .github/dependabot.yml")'
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
echo "old secrets"
sec_signals() { KOGUT_NOW=2026-11-03T12:00:00Z jq -c -f scripts/signals.jq; }
sec_fixture=tests/fixtures/secrets.json
sec_mixed="$(sec_signals <"$sec_fixture")"
# The fixture's repository with only the named secrets left.
sec_only() { jq -c --argjson names "$1" '.repos[0].secrets.items |= map(select(.name | IN($names[])))' "$sec_fixture" | sec_signals; }
sec_one="$(sec_only '["OLD_PAT", "NEW_TOKEN"]')"
sec_none_stale="$(sec_only '["NEW_TOKEN", "JUST_UNDER", "NEVER_EXPIRES"]')"
sec_unavailable="$(jq -c '.repos[0].secrets = {status: "unavailable", items: []}' "$sec_fixture" | sec_signals)"
sec_helpers='def item($n): .repos[0].secrets.items[] | select(.name == $n);
  def no_finding: .repos[0] | all(.findings[]; .key != "secrets:age");'

check "a secret is stale from the warning age, and not a second before it" \
  "$sec_helpers"' [item("AT_THE_LIMIT"), item("JUST_UNDER")] | map([.age_days, .stale]) == [[80, true], [79, false]]' "$sec_mixed"
check "an old secret is stale, and a new one is not" \
  "$sec_helpers"' [item("OLD_PAT"), item("NEW_TOKEN")] | map([.age_days, .stale]) == [[98, true], [14, false]]' "$sec_mixed"
check "a name the owner listed as not expiring is never stale" \
  "$sec_helpers"' item("NEVER_EXPIRES") | .age_days > 300 and (.stale | not)' "$sec_mixed"
check "a secret without a date is not stale and breaks nothing" \
  "$sec_helpers"' item("NO_DATE") | .age_days == null and (.stale | not)' "$sec_mixed"
check "the warning age comes from the policy" \
  "$sec_helpers"' item("OLD_PAT") | .stale | not' \
  "$(jq -c '.policy.secret_warn_days = 99' "$sec_fixture" | sec_signals)"
check "a snapshot without the settings still warns at 80 days" \
  "$sec_helpers"' .repos[0].secrets.warn_days == 80 and (item("NEVER_EXPIRES") | .stale)' \
  "$(jq -c '.policy |= del(.secret_warn_days, .secret_ignore)' "$sec_fixture" | sec_signals)"
check "secrets are listed oldest first, with names and dates only" \
  '.repos[0].secrets | ([.items[].name] == ["NEVER_EXPIRES", "OLD_PAT", "AT_THE_LIMIT", "JUST_UNDER", "NEW_TOKEN", "NO_DATE"])
     and all(.items[]; keys == ["age_days", "name", "stale", "updated_at"])' "$sec_mixed"
check "a value that somehow reached the snapshot stays out of the digest" \
  '.repos[0] | tojson | contains("hunter2") | not' \
  "$(jq -c '.repos[0].secrets.items[0].value = "hunter2"' "$sec_fixture" | sec_signals)"
check "one stale secret is a finding that names it and says it may have expired" \
  '.repos[0].findings[] | select(.key == "secrets:age") | .auto and .kind == "secrets" and .slug == "secrets-age"
     and .title == "Secrets: OLD_PAT is old enough that it may have expired"
     and .facts == {warn_days: 80, secrets: [{name: "OLD_PAT", updated_at: "2026-07-28T10:58:29Z", age_days: 98}]}' "$sec_one"
check "several stale secrets are one finding that counts them" \
  '[.repos[0].findings[] | select(.key == "secrets:age")] | length == 1
     and .[0].title == "Secrets: 2 secrets are old enough that they may have expired"
     and ([.[0].facts.secrets[].name] == ["OLD_PAT", "AT_THE_LIMIT"])' "$sec_mixed"
check "no stale secret, no finding" "$sec_helpers"' no_finding' "$sec_none_stale"
check "a list that could not be read says so, and is no finding" \
  "$sec_helpers"' (.repos[0].secrets == {status: "unavailable", warn_days: 80, items: []}) and no_finding' "$sec_unavailable"
check "a snapshot without secrets counts as not read" \
  "$sec_helpers"' (.repos[0].secrets.status == "unavailable") and no_finding' \
  "$(jq -c '.repos[0] |= del(.secrets)' "$sec_fixture" | sec_signals)"

sec_plan() {
  jq -c -n -L scripts --argjson d "$(jq -c '.repos[0]' <<<"$1")" --argjson issues "$2" \
    'include "issues"; plan($d; $issues; {}; "2026-11-03"; "https://example.com/kogut")'
}
sec_issue='[{"number": 6, "title": "Secrets: OLD_PAT is old enough that it may have expired", "url": "u6", "key": "secrets:age", "body": "old"}]'
check "the issue's facts give each secret's date and age, and say it goes by age" \
  '.[0] | .action == "open" and .key == "secrets:age" and (.body
     | contains("- `OLD_PAT`: last set on 2026-07-28, 98 days ago\n- GitHub does not say when a secret expires, so this goes by age: from 80 days, a token is old enough that it may have expired.")
       and contains("<!-- kogut-finding: secrets:age -->"))' "$(sec_plan "$sec_one" '[]')"
check "an issue's text never says a secret has expired" \
  '.[0] | [.title, .body] | all(.[]; gsub("may have expired"; "") | test("expired") | not)' "$(sec_plan "$sec_one" '[]')"
check "the issue closes once nothing is stale, saying why" \
  '.[0] | .action == "close" and .number == 6 and (.comment | contains("no secret is old enough that it may have expired"))' \
  "$(sec_plan "$sec_none_stale" "$sec_issue")"
check "the issue stays open when the list could not be read" \
  '.[0] | .action == "keep" and .number == 6' "$(sec_plan "$sec_unavailable" "$sec_issue")"
check "a failed read keeps only the secrets issue open" \
  '.[0] | .action == "close" and .number == 7' \
  "$(sec_plan "$sec_unavailable" '[{"number": 7, "title": "Repository hygiene gaps", "url": "u7", "key": "hygiene", "body": "old"}]')"

sec_digest() { jq -c -f scripts/digest.jq <<<"$1"; }
check "a stale secret makes the digest yellow and names it" \
  '.[0] | .status == "yellow" and (.text | contains("**Old secrets:** `OLD_PAT`, 98 days: old enough that it may have expired.") and (contains("Nothing needs you.") | not))' \
  "$(sec_digest "$sec_one")"
check "several stale secrets read in the plural" \
  '.[0].text | contains("**Old secrets:** `OLD_PAT`, 98 days; `AT_THE_LIMIT`, 80 days: old enough that they may have expired.")' \
  "$(sec_digest "$sec_mixed")"
check "secrets that are fine stay out of the digest" \
  '.[0] | .status == "green" and (.text | contains("ecrets") | not) and (.text | contains("Nothing needs you."))' \
  "$(sec_digest "$sec_none_stale")"
check "a list that could not be read is mentioned, and changes nothing else" \
  '.[0] | .status == "green" and (.text | contains("**Secrets:** could not be read.") and contains("Nothing needs you."))' \
  "$(sec_digest "$sec_unavailable")"

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
echo "why a workflow is red"
cause_of() { jq -c -f scripts/causes.jq <<<"$1"; }
check "a token GitHub refused reads as credentials" \
  '. == {kind: "credentials", signature: "github-bad-credentials"}' \
  "$(cause_of '{"jobs": [{"errors": ["Bad credentials - https://docs.github.com/rest"], "log": null}]}')"
check "an emulator that never booted reads as infra" \
  '. == {kind: "infra", signature: "android-emulator-boot-timeout"}' \
  "$(cause_of '{"jobs": [{"errors": ["Timeout waiting for emulator to boot."], "log": null}]}')"
check "a corrupt SDK download reads as infra, from the log" \
  '. == {kind: "infra", signature: "android-sdk-corrupt-download"}' \
  "$(cause_of '{"jobs": [{"errors": ["Process completed with exit code 1."], "log": "Warning: An error occurred while preparing SDK package Google APIs Intel x86_64 Atom System Image: Error reading Zip content from a SeekableByteChannel.\n"}]}')"
check "an image missing from the kind node reads as infra" \
  '. == {kind: "infra", signature: "kind-image-not-loaded"}' \
  "$(cause_of '{"jobs": [{"errors": ["ghcr.io/akogut/ephemeral-k8s-test-envs/aggregator:e69fac1 is not in the image store of preview-control-plane"], "log": null}]}')"
check "a registry refusing a pull reads as external" \
  '. == {kind: "external", signature: "registry-pull-refused"}' \
  "$(cause_of '{"jobs": [{"errors": [], "log": "docker: Error response from daemon: unauthorized: access to the requested resource is not authorized\n"}]}')"
check "the live platform not answering reads as external" \
  '. == {kind: "external", signature: "live-platform-not-ready"}' \
  "$(cause_of '{"jobs": [{"errors": [], "log": "Error: Restful Booker Platform is not ready after 29 attempts within 90000 ms\n"}]}')"
check "anything else is unknown, with no signature" \
  '. == {kind: "unknown", signature: null}' \
  "$(cause_of '{"jobs": [{"errors": ["Process completed with exit code 1."], "log": "BUILD FAILED in 12m 44s\n"}]}')"
check "a run with no failed jobs, or no jobs at all, is unknown" \
  '. == [{kind: "unknown", signature: null}, {kind: "unknown", signature: null}]' \
  "$(jq -cs . <<<"$(cause_of '{"jobs": []}') $(cause_of '{}')")"
check "a test suite saying Bad credentials is not a refused token" \
  'all(.[]; . == {kind: "unknown", signature: null})' \
  "$(jq -cs . <<<"$(cause_of '{"jobs": [{"errors": [], "log": "Bad credentials - https://docs.github.com/rest\n"}]}') $(cause_of '{"jobs": [{"errors": ["expected reason to equal Bad credentials - https://docs.github.com/rest"], "log": null}]}')")"
check "a log line alone cannot claim an annotation's signature, and an error line needs the whole message" \
  'all(.[]; . == {kind: "unknown", signature: null})' \
  "$(jq -cs . <<<"$(cause_of '{"jobs": [{"errors": [], "log": "Timeout waiting for emulator to boot.\n"}]}') $(cause_of '{"jobs": [{"errors": ["Timeout waiting for emulator to boot. Retried later"], "log": null}]}')")"
check "one job with an unexplained failure leaves the whole run unknown" \
  '. == {kind: "unknown", signature: null}' \
  "$(cause_of '{"jobs": [{"errors": ["Timeout waiting for emulator to boot."], "log": null}, {"errors": [], "log": "BUILD FAILED\n"}]}')"
check "a job that was not read leaves the whole run unknown" \
  '. == {kind: "unknown", signature: null}' \
  "$(cause_of '{"jobs": [{"errors": ["Timeout waiting for emulator to boot."], "log": null}, {"errors": [], "log": null}]}')"
check "a refused token outranks every other job" \
  '. == {kind: "credentials", signature: "github-bad-credentials"}' \
  "$(cause_of '{"jobs": [{"errors": [], "log": "BUILD FAILED\n"}, {"errors": ["Bad credentials - https://docs.github.com/rest"], "log": null}]}')"
check "infra next to an outage reads as the outage, and all infra stays infra" \
  '.[0].kind == "external" and .[1] == {kind: "infra", signature: "android-emulator-boot-timeout"}' \
  "$(jq -cs . <<<"$(cause_of '{"jobs": [{"errors": ["Timeout waiting for emulator to boot."], "log": null}, {"errors": [], "log": "Restful Booker Platform is not ready after 29 attempts\n"}]}') $(cause_of '{"jobs": [{"errors": ["Timeout waiting for emulator to boot."], "log": null}, {"errors": ["Timeout waiting for emulator to boot."], "log": null}]}')")"
check "a 5xx from Gradle's download server reads as external" \
  '. == {kind: "external", signature: "gradle-download-5xx"}' \
  "$(cause_of '{"jobs": [{"errors": ["Exception in thread \"main\" java.io.IOException: Server returned HTTP response code: 504 for URL: https://services.gradle.org/distributions/gradle-9.3.1-bin.zip"], "log": null}]}')"
check "a 5xx on a tool download reads as external, with or without the prefix" \
  'all(.[]; . == {kind: "external", signature: "tool-download-5xx"})' \
  "$(jq -cs . <<<"$(cause_of '{"jobs": [{"errors": ["Error: Unexpected HTTP response: 504"], "log": null}]}') $(cause_of '{"jobs": [{"errors": ["Unexpected HTTP response: 503"], "log": null}]}')")"
check "a download refused with a 4xx is not an outage" \
  'all(.[]; . == {kind: "unknown", signature: null})' \
  "$(jq -cs . <<<"$(cause_of '{"jobs": [{"errors": ["Error: Unexpected HTTP response: 404"], "log": null}]}') $(cause_of '{"jobs": [{"errors": ["Exception in thread \"main\" java.io.IOException: Server returned HTTP response code: 403 for URL: https://services.gradle.org/distributions/gradle-9.3.1-bin.zip"], "log": null}]}')")"
check "a kind download that fails its checksum reads as external, from the log" \
  'all(.[]; . == {kind: "external", signature: "kind-download-corrupt"})' \
  "$(jq -cs . <<<"$(cause_of '{"jobs": [{"errors": [], "log": "sha256sum: WARNING: 1 computed checksum did NOT match\nkind-linux-amd64: FAILED\n"}]}') $(cause_of '{"jobs": [{"errors": [], "log": "sha256sum: '"'"'standard input'"'"': no properly formatted checksum lines found\n"}]}')")"
check "the answer carries no text from the log" \
  'keys == ["kind", "signature"]' \
  "$(cause_of '{"jobs": [{"errors": ["Bad credentials - https://docs.github.com/rest"], "log": "something secret\n"}]}')"

ci_causes="$(KOGUT_NOW=2026-10-30T12:00:00Z jq -f scripts/signals.jq tests/fixtures/ci-causes.json)"
c_helpers='def w($r; $n): .repos[] | select(.name == $r) | .ci_failing[] | select(.name == $n);'
c_check() { check "$1" "$c_helpers $2" "$ci_causes"; }
c_check "infra past the streak is retried, and says why" \
  'w("settled"; "infra-past-streak") | .failing_streak == 4
     and .action == {name: "rerun", reason: "failed on infrastructure (android-emulator-boot-timeout), which a retry can clear"}
     and .held == null and .cause.kind == "infra"'
c_check "infra stops at the limit, so it cannot loop" \
  '[w("settled"; "infra-below-limit", "infra-at-limit") | .action.name] == ["rerun", null]'
c_check "infra is still retried once per run" \
  'w("settled"; "infra-retried") | .failing_streak == 4 and .action == null'
c_check "a short streak of infra reads like any other first retry" \
  'w("settled"; "infra-short") | .action == {name: "rerun", reason: "failed on the current head and not retried yet"}'
c_check "unknown and external do not pass the streak, and a snapshot without a cause is unknown" \
  '[w("settled"; "unknown-past-streak", "no-cause-past-streak", "external-past-streak") | .action] == [null, null, null]
     and (w("settled"; "no-cause-past-streak") | .cause == {kind: "unknown", signature: null})'
c_check "up to two failures in a row get the first retry whatever the cause" \
  'w("settled"; "unknown-two") | .failing_streak == 2 and .action.name == "rerun"'
c_check "an outage still gets the ordinary first retry" \
  'w("settled"; "external-short") | .action.name == "rerun" and .cause.signature == "live-platform-not-ready"'
c_check "a refused token is never retried or started, and says so" \
  '[w("settled"; "credentials-short", "credentials-past-streak", "credentials-older-commit")
     | .action == null and (.held | contains("a retry cannot fix that"))] == [true, true, true]'
c_check "a schedule that can cancel a run holds back a dispatch while the head is young" \
  'w("fresh"; "cron-cancel") | .action == null and (.held | contains("cancel-in-progress"))'
c_check "a day on the default branch lifts that hold" \
  'w("settled"; "cron-cancel-older-commit") | .action.name == "dispatch" and .held == null'
c_check "without a date on the head, the hold stays" \
  '(w("undated"; "cron-cancel") | .action == null and .held != null) and (w("undated"; "plain") | .action.name == "dispatch")'
c_check "a cron alone, cancel-in-progress alone, or neither does not hold a dispatch" \
  '[w("fresh"; "cron-only", "cancel-only", "plain") | .action.name] == ["dispatch", "dispatch", "dispatch"]'
c_check "the hold is about dispatch: a retry on the head goes on, and a workflow that cannot start says nothing" \
  '(w("fresh"; "cron-cancel-on-head") | .action.name == "rerun" and .held == null)
     and (w("fresh"; "cron-cancel-not-startable") | .action == null and .held == null)'
check "the digest names a known cause next to a red workflow, and only a known one" \
  '(.[0].text | contains("[Nightly](https://example/run), 4 in a row: credentials (github-bad-credentials)"))
     and (.[1].text | contains("[Nightly](https://example/run), 4 in a row") and (contains("unknown") | not))' \
  "$(digest_of '(quiet + {ci_failing: [run(".github/workflows/n.yml") + {cause: {kind: "credentials", signature: "github-bad-credentials"}}]}),
                (quiet + {ci_failing: [run(".github/workflows/n.yml") + {cause: {kind: "unknown", signature: null}}]})')"

echo
echo "auto-merge"
am_fixture=tests/fixtures/auto-merge.json
am="$(KOGUT_NOW=2026-10-30T12:00:00Z jq -f scripts/signals.jq "$am_fixture")"
am_helpers='def am($n): .repos[] | select(.name == "clean") | .dependabot_prs[] | select(.number == $n) | .auto_merge;
  def why($n; $text): any(am($n).why[]; contains($text));'
am_check() { check "$1" "$am_helpers $2" "$am"; }
am_check "a green deps-dev patch past the cooldown is eligible" 'am(1) == {eligible: true, why: []}'
am_check "a group of deps-dev patches is eligible" 'am(2).eligible'
am_check "a production update is not, by the title or by the metadata" \
  '(am(3).eligible | not) and why(3; "title does not say deps-dev") and why(3; "not direct:development")'
am_check "a deps-dev title does not outweigh the metadata" \
  'am(4) | (.eligible | not) and .why == ["the metadata names a dependency that is not direct:development"]'
am_check "the metadata does not outweigh the title" \
  'am(5) | (.eligible | not) and .why == ["the title does not say deps-dev"]'
am_check "an indirect dependency is not a dev dependency" \
  'am(6) | (.eligible | not) and .why == ["the metadata names a dependency that is not direct:development"]'
am_check "a minor is not a patch" '(am(7).eligible | not) and why(7; "a minor update, not a patch")'
am_check "a title that says patch does not outweigh the metadata" \
  'am(8) | (.eligible | not) and .why == ["the metadata does not call every update a semver patch"]'
am_check "a security update, which leaves out update-type, is not eligible" \
  'am(9) | (.eligible | not) and .why == ["the metadata does not call every update a semver patch"]'
am_check "one minor in a group keeps the group out" 'why(10; "does not call every update a semver patch") and (am(10).eligible | not)'
am_check "one production update in a group keeps the group out" 'why(11; "not direct:development") and (am(11).eligible | not)'
am_check "a head commit by someone else keeps the PR out" \
  'am(12) | (.eligible | not) and .why == ["the head commit is not only Dependabot'"'"'s"]'
am_check "so does a co-author" '(am(13).eligible | not) and why(13; "not only Dependabot")'
am_check "unknown authors count as someone else" '(am(14).eligible | not) and why(14; "not only Dependabot")'
am_check "a commit message that was not read keeps the PR out" \
  'am(15) | (.eligible | not) and .why == ["the head commit'"'"'s Dependabot metadata cannot be read"]'
am_check "a PR younger than the cooldown waits" \
  'am(16) | (.eligible | not) and .why == ["1 day old, and this tier waits the full 3-day cooldown"]'
am_check "a fix for a high alert skips the cooldown in the gate, but not here" \
  '(.repos[] | select(.name == "clean") | .dependabot_prs[] | select(.number == 17) | .ready_to_merge)
   and (am(17) | (.eligible | not) and .why == ["1 day old, and this tier waits the full 3-day cooldown"])'
am_check "a second block quoted in the message reads as nothing" 'why(18; "metadata cannot be read") and (am(18).eligible | not)'
am_check "a block with text after it reads as nothing" 'why(19; "metadata cannot be read") and (am(19).eligible | not)'
am_check "a block without its opening line reads as nothing, first or further down" \
  'why(20; "metadata cannot be read") and (am(20).eligible | not) and why(33; "metadata cannot be read") and (am(33).eligible | not)'
am_check "a block without its closing line reads as nothing" 'why(21; "metadata cannot be read") and (am(21).eligible | not)'
am_check "a field kogut does not know reads as nothing" 'why(22; "metadata cannot be read") and (am(22).eligible | not)'
am_check "an empty block reads as nothing" 'why(23; "metadata cannot be read") and (am(23).eligible | not)'
am_check "a block that opens without a name reads as nothing" \
  'why(31; "metadata cannot be read") and why(32; "metadata cannot be read")'
am_check "a major is out" '(am(24).eligible | not) and why(24; "a major update, not a patch")'
am_check "red checks keep a PR out, with the gate's reason" \
  'am(25) | (.eligible | not) and .why == ["not ready: checks are red"]'
am_check "a draft stays out" 'am(26) | (.eligible | not) and .why == ["not ready: draft"]'
am_check "a major split across PRs says what it belongs with" 'why(27; "belongs with #28")'
am_check "a title without the prefix stays out, and so does one that only mentions it" \
  'why(29; "title does not say deps-dev") and why(30; "title does not say deps-dev")'
check "a red default branch keeps every PR waiting" \
  '.repos[] | select(.name == "red") | .dependabot_prs[0].auto_merge
   | (.eligible | not) and .why == ["the default branch is red: Nightly"]' "$am"
check "a red run of Dependabot's own does not" \
  '.repos[] | select(.name == "own-red") | .dependabot_prs[0].auto_merge.eligible' "$am"
am_off() { jq "$1" "$am_fixture" | KOGUT_NOW=2026-10-30T12:00:00Z jq -f scripts/signals.jq; }
check "enabled: false merges nothing" \
  '.repos[0].dependabot_prs[0].auto_merge | (.eligible | not) and .why == ["auto-merge is off"]' \
  "$(am_off '.policy.auto_merge.enabled = false')"
check "a missing setting merges nothing" \
  '.repos[0].dependabot_prs[0].auto_merge | (.eligible | not) and .why == ["auto-merge is off"]' \
  "$(am_off 'del(.policy.auto_merge)')"
check "a setting of the wrong shape merges nothing" \
  '.repos[0].dependabot_prs[0].auto_merge | (.eligible | not) and .why == ["auto-merge is off"]' \
  "$(am_off '.policy.auto_merge = true')"
check "without a cooldown setting nothing is old enough" \
  '.repos[0].dependabot_prs[0].auto_merge | (.eligible | not) and any(.why[]; contains("waits the full unknown-day cooldown"))' \
  "$(am_off 'del(.policy.cooldown_days)')"
check "the config turns it on, with a limit" \
  '.policy.auto_merge | .enabled == true and (.limit_per_repo | type) == "number" and .limit_per_repo > 0' "$(cat kogut.config.json)"

echo
echo "feature requests"
# Each argument is a jq expression for an issue. Single-quoted, so the shell leaves it alone.
needs_of() {
  jq -cn 'def base: {labeled: [{actor: "example", at: "2026-11-01T00:00:00Z"}], approvals: [], labels: [{name: "kogut-feature"}], comments: []};
          def plan($at): {author: {login: "kogut-agent[bot]"}, createdAt: $at, body: "The plan\n<!-- kogut-plan -->"};
          def said($who; $at): {author: {login: $who}, createdAt: $at, body: "Words"};
          def approved($who; $at): .approvals += [{actor: $who, at: $at}] | .labels += [{name: "kogut-plan-approved"}];
          '"$1" |
    jq --arg owner example --arg app kogut-agent --argjson enabled "${2:-true}" --argjson prs "${3:-[]}" -f scripts/feature-state.jq
}
check "the owner's label asks for a plan first" '. == "plan"' "$(needs_of 'base')"
check "a repository outside policy.feature.repos takes none" '. == "not-enabled"' "$(needs_of 'base' false)"
check "someone else's label makes no feature request" '. == "unauthorized"' \
  "$(needs_of 'base | .labeled = [{actor: "mallory", at: "2026-11-01T00:00:00Z"}]')"
check "the latest label decides" '. == "unauthorized"' \
  "$(needs_of 'base | .labeled += [{actor: "mallory", at: "2026-11-02T00:00:00Z"}]')"
check "a kogut PR that names it carries it on" '. == "in-progress"' "$(needs_of 'base' true '[5]')"
check "a plan waits for the owner" '. == "owner"' "$(needs_of 'base | .comments = [plan("2026-11-02T00:00:00Z")]')"
check "the owner answering a plan asks for a new one" '. == "plan"' \
  "$(needs_of 'base | .comments = [plan("2026-11-02T00:00:00Z"), said("example"; "2026-11-03T00:00:00Z")]')"
check "the owner speaking before the plan changes nothing" '. == "owner"' \
  "$(needs_of 'base | .comments = [said("example"; "2026-11-01T12:00:00Z"), plan("2026-11-02T00:00:00Z")]')"
check "someone else answering a plan changes nothing" '. == "owner"' \
  "$(needs_of 'base | .comments = [plan("2026-11-02T00:00:00Z"), said("mallory"; "2026-11-03T00:00:00Z")]')"
check "the owner's approval after the plan lets kogut build" '. == "build"' \
  "$(needs_of 'base | .comments = [plan("2026-11-02T00:00:00Z")] | approved("example"; "2026-11-03T00:00:00Z")')"
check "an approval stands when the owner comments after it" '. == "build"' \
  "$(needs_of 'base | .comments = [plan("2026-11-02T00:00:00Z"), said("example"; "2026-11-04T00:00:00Z")] | approved("example"; "2026-11-03T00:00:00Z")')"
check "a new plan needs a new approval" '. == "owner"' \
  "$(needs_of 'base | .comments = [plan("2026-11-02T00:00:00Z"), plan("2026-11-04T00:00:00Z")] | approved("example"; "2026-11-03T00:00:00Z")')"
check "someone else's approval does not count" '. == "owner"' \
  "$(needs_of 'base | .comments = [plan("2026-11-02T00:00:00Z")] | approved("mallory"; "2026-11-03T00:00:00Z")')"
check "an approval label taken off again does not count" '. == "owner"' \
  "$(needs_of 'base | .comments = [plan("2026-11-02T00:00:00Z")] | approved("example"; "2026-11-03T00:00:00Z") | .labels = [{name: "kogut-feature"}]')"
check "an approval with no plan approves nothing" '. == "plan"' \
  "$(needs_of 'base | approved("example"; "2026-11-03T00:00:00Z")')"
check "a plan copied by someone else is no plan" '. == "plan"' \
  "$(needs_of 'base | .comments = [said("mallory"; "2026-11-02T00:00:00Z") + {body: "<!-- kogut-plan -->"}]')"
check "a comment from kogut without the marker is no plan" '. == "plan"' \
  "$(needs_of 'base | .comments = [said("kogut-agent[bot]"; "2026-11-02T00:00:00Z")]')"

features_in="$(jq '.policy.feature = {repos: ["alpha"], followup_limit: 8}
  | (.repos[] | select(.name == "alpha")).features = [
      {number: 90, title: "A feature", url: "https://example/90", labels: [], comments: [], approvals: [], labeled: [{actor: "example", at: "2026-10-01T00:00:00Z"}]}]
  | (.repos[] | select(.name == "beta")).features = [
      {number: 91, title: "Elsewhere", url: "https://example/91", labels: [], comments: [], approvals: [], labeled: [{actor: "example", at: "2026-10-01T00:00:00Z"}]}]
  | (.repos[] | select(.name == "alpha") | .prs[] | select(.number == 31)).body += "\n<!-- kogut-feature: 90 -->"' tests/fixtures/state.json |
  KOGUT_NOW=2026-10-30T12:00:00Z jq -f scripts/signals.jq)"
check "the digest lists a feature request with what it needs" \
  'repo("alpha") | .features == [{number: 90, title: "A feature", url: "https://example/90", prs: [], needs: "plan"}]' "$features_in"
check "only a repository in policy.feature.repos takes one" 'repo("beta") | .features[0].needs == "not-enabled"' "$features_in"
check "no setting means no repository takes one" \
  'repo("alpha") | .features == [] and all(.kogut_prs[]; .feature == false)' "$signals"
check "the daily digest says what a feature request waits for" \
  '(.[0].text | contains("**Feature plans waiting for you:** [#1]")) and .[0].status == "yellow"
   and (.[1].text | contains("**Features waiting for kogut:** [#1]")) and .[1].status == "yellow"' \
  "$(digest_of '(quiet + {features: [one + {needs: "owner"}]}), (quiet + {features: [one + {needs: "build"}]})')"

title_of() { printf '%s\n\n%s\n' "$1" "Body" >"$title_dir/text"; bash -c 'source scripts/lib.sh; kogut_fix_title "$1" "${2:-}"' _ "$title_dir/text" "${2:-}" 2>&1 | jq -Rs .; }
title_dir="$(mktemp -d)"
check "a feat title is refused on the maintenance path" 'contains("must be a maintenance Conventional Commit")' "$(title_of 'feat: a thing')"
check "a feat title passes only on the feature path" '. == "feat: a thing\n"' "$(title_of 'feat: a thing' feature)"
check "a maintenance title passes on either path" '. == "fix: a thing\n\n" or . == "fix: a thing\n"' "$(title_of 'fix: a thing' feature)"
check "the feature path still wants a Conventional Commit" 'contains("must be a feature Conventional Commit")' "$(title_of 'a thing' feature)"
rm -rf "$title_dir"

check "a feature cannot ask to change workflows" 'contains("cannot change .github/workflows/")' \
  "$(KOGUT_HOLD_FILE=/nonexistent ./scripts/open-fix-pr.sh flakemetry some-fix --feature 1 --workflows 2>&1 | jq -Rs .)"
check "a PR is a task or a feature, not both" 'contains("usage:")' \
  "$(KOGUT_HOLD_FILE=/nonexistent ./scripts/open-fix-pr.sh flakemetry some-fix --task 1 --feature 2 2>&1 | jq -Rs .)"

size_dir="$(mktemp -d)"
git -C "$size_dir" init -q
git -C "$size_dir" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m base
size_of() { bash -c 'source scripts/lib.sh; kogut_feature_size "$1" "${2:-}" && echo fits' _ "$size_dir" "${1:-}" 2>&1 | jq -Rs .; }
seq 1 1400 >"$size_dir/small.txt"
git -C "$size_dir" add -A
check "a feature within the limit fits" '. == "fits\n"' "$(size_of)"
check "what the PR already holds counts" 'contains("the limit is 1500")' \
  "$(size_of '{"files": [{"path": "other.txt", "additions": 200, "deletions": 0}]}')"
check "a file changed twice counts once" '. == "fits\n"' \
  "$(size_of '{"files": [{"path": "small.txt", "additions": 50, "deletions": 0}]}')"
seq 1 5000 >"$size_dir/package-lock.json"
mkdir -p "$size_dir/app"
seq 1 5000 >"$size_dir/app/pnpm-lock.yaml"
git -C "$size_dir" add -A
check "a lockfile does not count" '. == "fits\n"' "$(size_of)"
seq 1 1600 >"$size_dir/small.txt"
git -C "$size_dir" add -A
check "too many lines are refused" 'contains("changes 1600 lines") and contains("split it")' "$(size_of)"
seq 1 10 >"$size_dir/small.txt"
for i in $(seq 1 31); do echo x >"$size_dir/f$i.txt"; done
git -C "$size_dir" add -A
check "too many files are refused" 'contains("changes 32 files")' "$(size_of)"
rm -rf "$size_dir"

echo
echo "parallel work"
plan_of() {
  jq -cn 'def repo($n; $tasks; $features): {name: $n, tasks: $tasks, features: $features};
          def t($n): {number: $n, url: "u\($n)", needs: "start", auto: false};
          def f($n; $needs): {number: $n, url: "u\($n)", needs: $needs};
          '"$1" | jq -c -f scripts/task-plan.jq
}
check "one piece of work per repository, oldest first" \
  '([.run[] | [.repo, .number]] == [["a", 1]]) and ([.waiting[] | [.number, .why]] == [[2, "one piece of work per repository"]])' \
  "$(plan_of '{repos: [repo("a"; [t(2), t(1)]; [])], holds: {}, busy: {}, limit: 3}')"
check "several repositories run at once" '[.run[].repo] == ["a", "b"] and .waiting == []' \
  "$(plan_of '{repos: [repo("a"; [t(1)]; []), repo("b"; [t(2)]; [])], holds: {}, busy: {}, limit: 3}')"
check "the limit holds the rest back, and says so" \
  '[.run[].repo] == ["a", "b"] and ([.waiting[] | [.repo, .why]] == [["c", "over the limit of 2 at once"]])' \
  "$(plan_of '{repos: [repo("a"; [t(1)]; []), repo("b"; [t(2)]; []), repo("c"; [t(3)]; [])], holds: {}, busy: {}, limit: 2}')"
check "the owner's work goes before kogut's own, across repositories" '[.run[].number] == [5]' \
  "$(plan_of '{repos: [repo("a"; [t(1) + {auto: true}]; []), repo("b"; [t(5)]; [])], holds: {}, busy: {}, limit: 1}')"
check "a repository on hold waits" \
  '.run == [] and ([.waiting[] | [.number, .why]] == [[1, "on hold"], [2, "on hold"]])' \
  "$(plan_of '{repos: [repo("a"; [t(1), t(2)]; [])], holds: {a: "on hold since x"}, busy: {}, limit: 3}')"
check "a repository with a fix in progress waits" \
  '.run == [] and (.waiting[0].why == "a fix is in progress: my-fix")' \
  "$(plan_of '{repos: [repo("a"; [t(1)]; [])], holds: {}, busy: {a: ["my-fix"]}, limit: 3}')"
check "a feature that needs a plan or may build counts, one waiting for the owner does not" \
  '([.run[] | [.repo, .lane, .needs]] == [["a", "feature", "plan"], ["b", "feature", "build"]]) and .waiting == []' \
  "$(plan_of '{repos: [repo("a"; []; [f(1; "plan")]), repo("b"; []; [f(2; "build")]), repo("c"; []; [f(3; "owner"), f(4; "in-progress"), f(5; "unauthorized"), f(6; "not-enabled")])], holds: {}, busy: {}, limit: 3}')"
check "a task that needs nothing, or a repository that could not be read, gives no work" '.run == [] and .waiting == []' \
  "$(plan_of '{repos: [repo("a"; [t(1) + {needs: "owner"}, t(2) + {needs: "in-progress"}, t(3) + {needs: "unauthorized"}]; []), {name: "b", error: "boom"}], holds: {}, busy: {}, limit: 3}')"
check "the config sets a limit" '.policy.parallel_agents > 0 and (.policy.feature.repos | length) > 0' "$(cat kogut.config.json)"

echo
echo "hold"
hold_dir="$(mktemp -d)"
hold_file="$hold_dir/hold.json"
held_out() { KOGUT_HOLD_FILE="$hold_file" bash -c 'source scripts/lib.sh; if why="$(kogut_held "$1")"; then echo "held: $why"; else echo free; fi' _ "$1" 2>&1 | jq -Rs .; }
check "no file means no hold" '. == "free\n"' "$(held_out flakemetry)"
printf '{"repos":{"flakemetry":{"since":"2026-11-03T10:00:00Z","reason":"my work"}}}' >"$hold_file"
check "a repository on hold says since when and why" \
  '. == "held: on hold since 2026-11-03T10:00:00Z: my work\n"' "$(held_out flakemetry)"
check "the others are free" '. == "free\n"' "$(held_out mobile-task-manager-automation)"
for broken in '' 'not json' '[]' '{"repos":[]}' '{"other":{}}' '{"repos":{}} {"repos":{}}'; do
  printf '%s' "$broken" >"$hold_file"
  check "a hold file reading '$broken' holds everything" 'startswith("held: on hold, because the hold file cannot be read")' "$(held_out flakemetry)"
done
rm -f "$hold_file"
mkdir "$hold_file"
check "a directory in its place holds everything" 'startswith("held: on hold, because")' "$(held_out flakemetry)"
rmdir "$hold_file"
ln -s "$hold_dir/nowhere" "$hold_file"
check "a broken link holds everything" 'startswith("held: on hold, because")' "$(held_out flakemetry)"
rm -f "$hold_file"

hold() { KOGUT_HOLD_FILE="$hold_file" ./scripts/hold.sh "$@" 2>&1 | jq -Rs .; }
check "on names one repository, with its reason" \
  'startswith("flakemetry: on hold since ") and endswith(": building\n")' "$(hold on flakemetry --reason building)"
check "the rest stays free" 'contains("mobile-task-manager-automation: not on hold") and contains("flakemetry: on hold since")' "$(hold status)"
check "off lifts it" '. == "flakemetry: not on hold\n"' "$(hold off flakemetry)"
check "on with no repository holds all of them" \
  '[split("\n")[] | select(. != "")] | length == 6 and all(.[]; contains(": on hold since "))' "$(hold on)"
check "off with one repository leaves the others on hold" \
  'contains("flakemetry: on hold") and contains("mobile-task-manager-automation: not on hold")' \
  "$(hold off mobile-task-manager-automation >/dev/null; hold status)"
check "off with no repository lifts them all" \
  '[split("\n")[] | select(. != "")] | length == 6 and all(.[]; contains(": not on hold"))' "$(hold off)"
check "a repository outside the config is refused" 'contains("is not in kogut.config.json")' "$(hold on nowhere)"
printf 'broken' >"$hold_file"
check "a hold file that cannot be read is not overwritten" 'contains("cannot be read")' "$(hold off)"
check "and it is left as it was" '. == "broken"' "$(jq -Rs . <"$hold_file")"
rm -f "$hold_file"

printf '{"repos":{"flakemetry":{"since":"2026-11-03T10:00:00Z","reason":"my work"}}}' >"$hold_file"
refused() { KOGUT_HOLD_FILE="$hold_file" "$@" 2>&1 | jq -Rs .; }
for call in \
  'merge-dependabot.sh flakemetry 1' \
  'merge-dependabot.sh flakemetry 1 --dry-run' \
  'dependabot-command.sh flakemetry 1 rebase' \
  'run-workflow.sh flakemetry .github/workflows/ci.yml dispatch' \
  'open-fix-pr.sh flakemetry some-fix' \
  'update-fix-pr.sh flakemetry some-fix' \
  'task-reply.sh flakemetry 1' \
  'task-reply.sh flakemetry 1 --plan' \
  'dismiss-alert.sh flakemetry x package-lock.json --reason not_used --comment y' \
  'prune-branches.sh flakemetry --dry-run'; do
  # shellcheck disable=SC2086 # the call is split on purpose
  check "a hold stops $call" 'contains("flakemetry is on hold since") and contains("Nothing was done")' "$(refused ./scripts/$call)"
done
rm -rf "$hold_dir"

check "merge-dependabot.sh refuses --head with a list" 'contains("--head takes one PR")' \
  "$(KOGUT_HOLD_FILE=/nonexistent ./scripts/merge-dependabot.sh flakemetry 1 2 --head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2>&1 | jq -Rs .)"
check "merge-dependabot.sh refuses a --head that is not a commit id" 'contains("--head takes a full commit id")' \
  "$(KOGUT_HOLD_FILE=/nonexistent ./scripts/merge-dependabot.sh flakemetry 1 --head abc 2>&1 | jq -Rs .)"

digest_full() {
  jq -cn 'def quiet: {name: "r", url: "https://example/r", ci_failing: [], dependabot_prs: [], kogut_prs: [],
            tasks: [], other_prs: [], workflows_disabled: [], hygiene_issues: []};
          '"$1" | jq -c -f scripts/digest.jq
}
check "the digest says a repository is on hold, without changing the colour" \
  '.[0] | .status == "green" and (.text | contains("**On hold:** since 2026-11-03: my work") and contains("Nothing needs you."))' \
  "$(digest_full '{repos: [quiet], holds: {r: "on hold since 2026-11-03: my work"}}')"
check "the digest stays quiet about a hold on another repository" \
  '.[0].text | contains("On hold") | not' "$(digest_full '{repos: [quiet], holds: {other: "on hold since x"}}')"
check "the digest lists today's auto-merges for its repository, without changing the colour" \
  '.[0] | .status == "green" and (.text | contains("**Auto-merged:** [#1](https://example/r/pull/1), [#2](https://example/r/pull/2)") and contains("Nothing needs you.") and (contains("#3") | not))' \
  "$(digest_full '{repos: [quiet], auto_merged: [{repo: "r", pr: 1, outcome: "merged"}, {repo: "r", pr: 2, outcome: "merged"}, {repo: "other", pr: 3, outcome: "merged"}]}')"
check "the digest lists refusals, with why" \
  '.[0].text | contains("**Auto-merge refused:**\n- [#4](https://example/r/pull/4): checks are red") and (contains("Auto-merged") | not) and (contains("Nothing needs you.") | not)' \
  "$(digest_full '{repos: [quiet], auto_merged: [{repo: "r", pr: 4, outcome: "refused", reason: "checks are red"}]}')"
check "the digest says the merges are the only change, and otherwise that it changed nothing" \
  '(.[0].text | startswith("*Daily digest: the merges below are all kogut changed.*"))
   and (.[1].text | startswith("*Daily digest: read-only, nothing was changed.*"))' \
  "$(digest_full '{repos: [quiet, (quiet + {name: "s"})], auto_merged: [{repo: "r", pr: 1, outcome: "merged"}, {repo: "s", pr: 2, outcome: "refused", reason: "x"}]}')"
check "a later merge settles an earlier refusal of the same PR" \
  '.[0].text | contains("**Auto-merged:** [#1]") and (contains("refused") | not)' \
  "$(digest_full '{repos: [quiet], auto_merged: [{repo: "r", pr: 1, outcome: "refused", reason: "x"}, {repo: "r", pr: 1, outcome: "merged"}]}')"
check "the digest works without holds or records" '.[0].status == "green"' "$(digest_full '{repos: [quiet]}')"

echo
echo "issues.sh, a real run"
# --dry-run skips the writes and the steps around them, so a bug there goes
# unseen. This runs a copy of the scripts with the collection, the App's token
# and gh faked, so nothing reaches GitHub or reads the App's key.
issues_dir="$(mktemp -d)"
issues_log="$issues_dir/gh.log"
: >"$issues_log"
mkdir "$issues_dir/bin"
cp -R scripts kogut.config.json "$issues_dir/"
echo 'kogut_app_token() { echo test-token; }' >>"$issues_dir/scripts/lib.sh"
cat >"$issues_dir/scripts/collect.sh" <<'EOF'
#!/usr/bin/env bash
jq -cn '{key: "secrets:age", kind: "secrets", auto: true, title: "Secrets: X", slug: "secrets-age",
         facts: {warn_days: 80, secrets: [{name: "X", updated_at: "2026-01-01T00:00:00Z", age_days: 100}]}} as $f
  | {repos: [$ARGS.positional[] | {name: ., error: null, findings: [$f]}]}' --args "$@"
EOF
cat >"$issues_dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "${GH_TOKEN:-no-token} $(tr '\n' ' ' <<<"$*")" >>"$GH_LOG"
case "$*" in
  *"issues?state=open"*) echo '[]' ;;
  "api repos/"*"/labels/"*) exit 1 ;;
  "api -X POST repos/"*"/issues --input -"*) cat >/dev/null; echo '#1 https://github.test/1' ;;
esac
EOF
chmod +x "$issues_dir/bin/gh"
issues_status=0
issues_out="$(GH_LOG="$issues_log" KOGUT_HOLD_FILE=/nonexistent PATH="$issues_dir/bin:$PATH" \
  "$issues_dir/scripts/issues.sh" mobile-task-manager-automation flakemetry 2>&1)" || issues_status=$?
check "a real run finishes and opens the issue in each repository" \
  '.status == 0 and ([.out | scan("opened #1")] | length == 2)' \
  "$(jq -cn --argjson status "$issues_status" --arg out "$issues_out" '{$status, $out}')"
check "the feature label is asked for only where features are on" \
  'contains("mobile-task-manager-automation/labels/kogut-feature") and (contains("flakemetry/labels/kogut-feature") | not)' \
  "$(jq -Rs . "$issues_log")"
check "every call carries the App's token" \
  'split("\n") | map(select(. != "")) | length > 0 and all(startswith("test-token "))' \
  "$(jq -Rs . "$issues_log")"
rm -rf "$issues_dir"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
