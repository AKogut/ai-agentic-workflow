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
'

passed=0
failed=0
check() {
  if jq -e "$helpers $2" <<<"$signals" >/dev/null; then
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
echo "workflows on the default branch"
check "consecutive failures form a streak, with the last success" \
  'repo("alpha") | .ci_failing == [{name: "CI", path: ".github/workflows/ci.yml", failing_streak: 2, of_runs: 4,
     last_success_at: "2026-10-27T09:00:00Z",
     latest_run: {id: 11, event: "push", conclusion: "failure", created_at: "2026-10-29T09:00:00Z",
                  url: "https://github.com/example/alpha/actions/runs/11"}}]'
check "a failure followed by a pass is flaky, not failing" \
  'repo("alpha") | .ci_flaky == [{name: "Nightly", path: ".github/workflows/nightly.yml", failures: 1, of_runs: 3}]'
check "cancelled runs say nothing about health" \
  'repo("alpha") | [.ci_failing[], .ci_flaky[]] | map(.name) | index("Report") == null'
check "disabled workflows are listed with the reason" \
  'repo("alpha") | .workflows_disabled == [{name: "Old nightly", path: ".github/workflows/old-nightly.yml", state: "disabled_inactivity"}]'

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
  'repo("beta") | .alerts == {total: 0, by_severity: {}, packages: []}'

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
