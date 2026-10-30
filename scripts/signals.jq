# Turns the raw snapshot (.kogut/state.json) into the signals digest: per
# repository, only what needs attention. Every rule that needs no judgement
# lives here rather than in the prompt, so no PR body can argue with it.

# Ages are measured from KOGUT_NOW when it is set (the tests pin the clock with
# it), otherwise from the current time.
def now_ts: if $ENV.KOGUT_NOW then $ENV.KOGUT_NOW | fromdateiso8601 else now end;
def days_since: (now_ts - fromdateiso8601) / 86400 | floor;

def ok_result: IN("SUCCESS", "SKIPPED", "NEUTRAL");
def bad_result: IN("FAILURE", "TIMED_OUT", "CANCELLED", "ERROR", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE");

# One entry per check on a PR, whether it came from Actions or a commit status.
# A check run still in progress has an empty conclusion.
def checks:
  [.statusCheckRollup[]? | {
    name: (.name // .context),
    result: ((.conclusion // "") as $c | if $c != "" then $c else (.state // "PENDING") end | ascii_upcase),
    url: (.detailsUrl // .targetUrl)
  }];

def checks_state($checks):
  if ($checks | length) == 0 then "none"
  elif any($checks[]; .result | bad_result) then "red"
  elif all($checks[]; .result | ok_result) then "green"
  else "pending" end;

def failing($checks): [$checks[] | select(.result | bad_result) | {name, url}];

# "bump x from 1.2.3 to 2.0.0" → {from, to, semver}. Null for group PRs, whose
# title carries no versions.
def bump:
  [.title | capture("from v?(?<from>[0-9][^ ]*) to v?(?<to>[0-9][^ ]*)")] | first
  | if . == null then null else
      (.from | split(".")) as $f | (.to | split(".")) as $t
      | . + {semver: (
          if $f[0] != $t[0] then "major"
          elif ($f[1] // "0") != ($t[1] // "0") then "minor"
          else "patch" end)}
    end;

# The merge gate. A PR is ready only when nothing below applies; the model may
# hold a ready PR back, but never merges past a blocker.
def dependabot_pr($required; $p):
  checks as $c
  | checks_state($c) as $state
  | (.createdAt | days_since) as $age
  | {
      number, title, url,
      age_days: $age,
      bump: bump,
      checks: $state,
      failing: failing($c),
      mergeable,
      blockers: [
        (if $state != "green" then "checks are \($state)" else empty end),
        (if ($required | length) == 0 then "no required checks on the default branch" else empty end),
        (if $state == "green" then
          ($required[] as $name
            | select([$c[] | select(.name == $name) | .result | ok_result] | any | not)
            | "required check '\($name)' did not run")
        else empty end),
        (if .mergeable != "MERGEABLE" then "mergeable: \(.mergeable)" else empty end),
        (if .isDraft then "draft" else empty end),
        (if $age < $p.cooldown_days then "younger than the \($p.cooldown_days)-day cooldown" else empty end)
      ]
    }
  | .ready_to_merge = (.blockers | length == 0);

def other_pr($p):
  checks as $c
  | (.createdAt | days_since) as $age
  | {
      number, title, url,
      author: .author.login,
      draft: .isDraft,
      age_days: $age,
      checks: checks_state($c),
      failing: failing($c),
      stale: ($age >= $p.stale_pr_days)
    };

# Open Dependabot alerts, summed by severity and grouped per package, worst
# first: one repository can carry a hundred alerts for a dozen packages. The
# individual alerts stay in the snapshot.
def severity_rank: {critical: 4, high: 3, medium: 2, low: 1}[.] // 0;

def alert_summary:
  {
    total: length,
    by_severity: (reduce .[] as $a ({}; .[$a.severity] += 1)),
    packages: (group_by(.package) | map(
      max_by(.severity | severity_rank) as $worst
      | {
          package: $worst.package,
          severity: $worst.severity,
          count: length,
          patched: ([.[].patched | select(. != null)] | unique),
          url: $worst.url
        })
      | sort_by(-(.severity | severity_rank), -.count, .package))
  };

# Health of one workflow on the default branch, newest run first. Cancelled
# and skipped runs say nothing about health and are left out.
def health($runs):
  ($runs | map(select(.status == "completed"
    and (.conclusion | IN("success", "failure", "timed_out", "startup_failure"))))) as $done
  | {
      total: ($done | length),
      failures: ($done | map(select(.conclusion != "success")) | length),
      streak: (($done | map(.conclusion == "success") | index(true)) // ($done | length)),
      latest: ($done[0] // null),
      last_success_at: ($done | map(select(.conclusion == "success")) | first | .created_at?)
    };

.policy as $p
| {
  generated_at,
  policy: $p,
  repos: [.repos[] | if .error then {name, error} else
    . as $r
    | .required_checks as $required
    | [.workflows[] | select(.state == "active") | . + {health: health($r.runs[.id | tostring] // [])}] as $active
    # Snapshots taken before last_commit_at was collected fall back to pushed_at.
    | (.repo.last_commit_at // .repo.pushed_at | days_since) as $idle
    | {
        name,
        url: .repo.html_url,
        default_branch: .repo.default_branch,
        dependabot_prs: [.prs[] | select(.author.login == "app/dependabot") | dependabot_pr($required; $p)],
        other_prs: [.prs[] | select(.author.login != "app/dependabot") | other_pr($p)],
        ci_failing: [$active[] | select(.health.streak > 0) | {
          name, path,
          failing_streak: .health.streak,
          of_runs: .health.total,
          last_success_at: .health.last_success_at,
          latest_run: (.health.latest | {id, event, conclusion, created_at, url})
        }],
        ci_flaky: [$active[] | select(.health.streak == 0 and .health.failures > 0) | {
          name, path, failures: .health.failures, of_runs: .health.total
        }],
        workflows_disabled: [.workflows[] | select(.state != "active") | {name, path, state}],
        alerts: (.alerts.items | alert_summary),
        hygiene: {
          required_checks: $required,
          auto_merge: .repo.allow_auto_merge,
          delete_branch_on_merge: .repo.delete_branch_on_merge,
          dependabot_config: .dependabot_config,
          dependabot_alerts: .alerts.status,
          days_since_commit: $idle,
          local_clone: .local_clone
        },
        hygiene_issues: [
          (if ($required | length) == 0 then
            "no required status checks on \(.repo.default_branch): a PR without checks would look green" else empty end),
          (if .repo.allow_auto_merge | not then "auto-merge is disabled" else empty end),
          (if .dependabot_config | not then "no .github/dependabot.yml" else empty end),
          (if .alerts.status == "disabled" then "Dependabot alerts are disabled" else empty end),
          (if .alerts.status == "unavailable" then "Dependabot alerts could not be read" else empty end),
          (if $idle >= $p.inactivity_warn_days then
            "no commits on \(.repo.default_branch) for \($idle) days: GitHub disables scheduled workflows after 60"
          else empty end),
          (if .local_clone.present | not then "no local clone at \(.local_clone.path)" else empty end),
          (if .repo.delete_branch_on_merge | not then "merged branches are not deleted" else empty end)
        ]
      }
  end]
}
