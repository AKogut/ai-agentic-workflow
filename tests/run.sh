#!/usr/bin/env bash
# Runs the policy in scripts/signals.jq against a fixed snapshot and checks
# each rule. KOHUT_NOW pins the clock, so the ages in the fixture never drift.
#
#   ./tests/run.sh
# The single-quoted strings are jq programs, and their $variables belong to jq.
# shellcheck disable=SC2016
set -euo pipefail
cd "$(dirname "$0")/.."

signals="$(KOHUT_NOW=2026-10-30T12:00:00Z jq -f scripts/signals.jq tests/fixtures/state.json)"
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

echo
echo "version bumps"
check "patch, minor and major are read from the title" \
  '[pr("alpha"; 1, 4, 2) | .bump.semver] == ["patch", "minor", "major"]'
check "a group PR carries no single version" \
  'pr("alpha"; 3) | .bump == null'

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
      "Dependabot alerts are disabled", "no pushes for 50 days", "no local clone", "merged branches are not deleted"]
   | all(. as $gap | any($issues[]; startswith($gap)))'
check "open alerts pass through" \
  'repo("alpha") | .alerts | length == 1 and .[0].severity == "high"'
check "a repository that failed to collect keeps its error and nothing else" \
  'repo("gamma") == {name: "gamma", error: "gh: Not Found (HTTP 404)"}'

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
