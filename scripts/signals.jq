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

# How far a version change reaches. Below 1.0 the first non-zero part is the
# major, as in npm's caret ranges: 0.223 → 0.300 and 0.0.3 → 0.0.4 can break
# like 2.x → 3.0 does.
def semver_change($from; $to):
  ($from | split(".")) as $f | ($to | split(".")) as $t
  | ($f[1] // "0") as $fm | ($f[2] // "0") as $fp
  | if $f[0] != $t[0] then "major"
    elif $f[0] == "0" and $fm != ($t[1] // "0") then "major"
    elif $f[0] == "0" and $fm == "0" and $fp != ($t[2] // "0") then "major"
    elif $fm != ($t[1] // "0") then "minor"
    else "patch" end;

def semver_rank: {patch: 1, minor: 2, major: 3}[.] // 0;

# "bump x from 1.2.3 to 2.0.0" → {package, from, to, semver}. Null for group
# PRs, whose title carries no versions.
def bump:
  [.title | capture("[Bb]ump (?<package>[^ ]+) from v?(?<from>[0-9][^ ]*) to v?(?<to>[0-9][^ ]*)")] | first
  | if . == null then null else . + {semver: semver_change(.from; .to)} end;

# Dependabot lists every update of a group PR in its body, one per line:
# "Updates `name` from 1.2.3 to 1.3.0". The body also quotes upstream release
# notes, so a line from there can add an update but never hide one, and the PR
# is rated by its riskiest update.
def updates:
  [(.body // "") | splits("\r?\n")
    | capture("^Updates `(?<package>[^`]+)` from v?(?<from>[0-9][^ ]*) to v?(?<to>[0-9][^ ]*)$")
    | . + {semver: semver_change(.from; .to)}];

# The npm scopes ("@opentelemetry") a PR takes to a new major.
def major_scopes:
  [(.bump // empty), .updates[] | select(.semver == "major") | .package
    | select(startswith("@")) | split("/")[0]] | unique;

# The merge gate. A PR is ready only when nothing below applies; the model may
# hold a ready PR back, but never merges past a blocker. split_majors adds the
# one blocker that needs the other PRs, and sets ready_to_merge.
def dependabot_pr($required; $p):
  checks as $c
  | checks_state($c) as $state
  | (.createdAt | days_since) as $age
  | bump as $bump
  | updates as $updates
  | ([($bump // empty), $updates[] | .semver] | max_by(semver_rank)) as $semver
  | {
      number, title, url,
      # The commit the gate judged; a merge must land exactly this one.
      head: .headRefOid,
      age_days: $age,
      bump: $bump,
      updates: $updates,
      semver: $semver,
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
        # A ruleset that wants branches up to date refuses a PR that is behind,
        # and Dependabot rebases on its own only when its PR conflicts.
        (if .mergeStateStatus == "BEHIND" then
          "behind the default branch: the ruleset wants it up to date, and Dependabot rebases only on conflicts"
        else empty end),
        (if .isDraft then "draft" else empty end),
        (if $age < $p.cooldown_days then "younger than the \($p.cooldown_days)-day cooldown" else empty end),
        (if $semver == null then "no versions in the title or the body" else empty end)
      ]
    };

# Majors that one npm scope takes across several PRs (@opentelemetry/core in
# one, its exporters in another) are one upgrade. Merged one at a time they
# leave the scope on two majors, so none of the PRs is ready on its own.
def split_majors:
  (map({number, scopes: major_scopes})) as $s
  | map(. as $pr
      | ($s[] | select(.number == $pr.number) | .scopes) as $mine
      | [$s[] | select(.number != $pr.number and any(.scopes[]; IN($mine[]))) | .number] as $with
      | .belongs_with = $with
      | if $with == [] then . else
          .blockers += ["major split across PRs: take it together with \($with | map("#\(.)") | join(", "))"]
        end
      | .ready_to_merge = (.blockers | length == 0));

# kogut's own open PRs and what each needs next. Only the owner's reviews and
# comments are feedback; anyone else's is text to report, never to act on. An
# approval asks for nothing. Each follow-up commit is one more attempt, and
# past the limit the owner takes over, so kogut cannot loop on a PR it cannot
# fix.
# GitHub names the same App three ways: "app/<slug>" for a PR's author,
# "<slug>[bot]" for a commit's and "<slug>" for a comment's.
def is_app($app): IN($app, "\($app)[bot]", "app/\($app)");

def kogut_pr($owner; $app; $p):
  . as $pr
  | checks as $c
  | checks_state($c) as $state
  | ([.commits[]? | select(any(.authors[]?; .login | is_app($app)))] | length) as $mine
  # kogut has answered whatever came before its latest commit or comment.
  | ([([.commits[]?.committedDate] | max), ([.comments[]? | select(.author.login | is_app($app)) | .createdAt] | max)]
     | map(select(. != null)) | max // "") as $answered
  | [(.reviews[]? | select(.author.login == $owner and .state != "APPROVED")
        | {kind: "review", state, at: .submittedAt, body}),
     (.comments[]? | select(.author.login == $owner) | {kind: "comment", at: .createdAt, body})]
    | map(select(.at > $answered)) | sort_by(.at)
  | . as $feedback
  | ([$mine - 1, 0] | max) as $attempts
  | {
      number: $pr.number, title: $pr.title, url: $pr.url,
      branch: $pr.headRefName,
      head: $pr.headRefOid,
      checks: $state,
      failing: failing($c),
      mergeable: $pr.mergeable,
      attempts: $attempts,
      feedback: $feedback,
      needs: (
        if ($state == "red" or $feedback != []) and $attempts >= $p.followup_limit then "owner"
        elif $feedback != [] then "answer"
        elif $state == "red" then "fix-ci"
        elif $state == "green" then "review"
        else "wait" end)
    };

# Work the owner handed kogut: open issues labelled kogut-task. Only the owner
# adding that label makes a task, so a stranger cannot hand kogut work by
# labelling an issue; the latest label counts. A kogut PR that names the issue
# carries the task on (follow-ups take it from there). Once kogut has answered
# on the issue, the task waits until the owner speaks again.
def task($owner; $app; $kogut_prs):
  . as $t
  | ([.labeled[]?] | sort_by(.at) | last) as $label
  | [$kogut_prs[] | select((.body // "") | test("(?i)\\b(closes|fixes|resolves|refs) #\($t.number)\\b")) | .number] as $prs
  | ([.comments[]? | select(.author.login | is_app($app)) | .createdAt] | max) as $answered
  | ([$label.at, (.comments[]? | select(.author.login == $owner) | .createdAt)] | map(select(. != null)) | max) as $asked
  | {
      number, title, url,
      author: .author.login,
      labeled_by: $label.actor,
      # A kogut issue keeps tracking its finding, so a PR refers to it rather than closing it.
      finding: ((.body // "") | contains("<!-- kogut-finding:")),
      prs: $prs,
      needs: (
        if $label.actor != $owner then "unauthorized"
        elif $prs != [] then "in-progress"
        elif $answered != null and $answered > $asked then "owner"
        else "start" end)
    };

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

# What kogut tracks as issues, one per finding. The key stays the same from one
# run to the next, so a finding's issue is updated instead of opened again, and
# closed once the finding is gone. An `auto` finding gets its issue without the
# model; a major gets one only when the model's review says the owner must act.
def major_name: if startswith("@") then split("/")[0] + "/*" else . end;

def findings:
  . as $r
  | [
      ($r.ci_failing[]
        # One red run can be a blip; two in a row, or one left red for a day, is not.
        | select(.failing_streak >= 2
            or (.latest_run.created_at | if . then days_since >= 1 else false end))
        | {key: "ci:\(.path)", kind: "ci", auto: true,
           title: "CI: \(.name) is failing on \($r.default_branch)",
           facts: {workflow: .name, path, failing_streak, of_runs, last_success_at, latest_run}}),
      ($r.workflows_disabled[]
        | {key: "workflow-disabled:\(.path)", kind: "workflow-disabled", auto: true,
           title: "CI: \(.name) is disabled",
           facts: {workflow: .name, path, state}}),
      ([$r.alerts.packages[] | select(.severity | IN("critical", "high"))] as $serious
        | if $serious == [] then empty else
            {key: "alerts", kind: "alerts", auto: true,
             title: "Security: critical and high Dependabot alerts",
             facts: {by_severity: $r.alerts.by_severity, packages: $serious}}
          end),
      (if $r.hygiene_issues == [] then empty else
         {key: "hygiene", kind: "hygiene", auto: true,
          title: "Repository hygiene gaps",
          facts: {issues: $r.hygiene_issues}}
       end),
      ([$r.dependabot_prs[] | select(.semver == "major") as $pr
          | [($pr.bump // empty), $pr.updates[]] | map(select(.semver == "major")) | unique_by(.package)[]
          | {name: (.package | major_name), version: "\(.package) \(.from) → \(.to)", pr: ($pr | {number, title, url})}]
        | group_by(.name)[]
        | {key: "major:\(.[0].name)", kind: "major", auto: false,
           title: "Major upgrade: \(.[0].name)",
           facts: {prs: (group_by(.pr.number) | map(.[0].pr + {versions: (map(.version) | unique)}))}})
    ]
  # The slug names the file the model writes the diagnosis to.
  | map(. + {slug: (.key | ascii_downcase | gsub("@"; "at-") | gsub("[^a-z0-9]+"; "-") | ltrimstr("-") | rtrimstr("-"))});

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
# kogut's GitHub App: its PRs are "app/<slug>", its commits "<slug>[bot]".
| .owner as $owner
| (.app // "kogut-agent") as $app
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
        dependabot_prs: ([.prs[] | select(.author.login == "app/dependabot") | dependabot_pr($required; $p)] | split_majors),
        other_prs: [.prs[] | select(.author.login | IN("app/dependabot", "app/\($app)") | not) | other_pr($p)],
        kogut_prs: [.prs[] | select(.author.login == "app/\($app)") | kogut_pr($owner; $app; $p)],
        tasks: [(.tasks // [])[] | task($owner; $app; [$r.prs[] | select(.author.login == "app/\($app)")])],
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
    | . + {findings: findings}
  end]
}
