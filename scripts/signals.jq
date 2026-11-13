include "feature" {search: "./"};

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
    url: (.detailsUrl // .targetUrl),
    at: (.completedAt // .startedAt)
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

# Dependabot names each update of a group PR in its body, in a table at the top
# ("| [name](url) | `1.2.3` | `1.3.0` |") and in an "Updates `name` from 1.2.3
# to 1.3.0" line. A long body is cut short, so some updates are only in the
# table. One line yields at most one update.
def body_updates:
  splits("\r?\n")
  | [capture("^Updates `(?<package>[^`]+)` from v?(?<from>[0-9][^ ]*) to v?(?<to>[0-9][^ ]*)$"),
     capture("^\\| \\[(?<package>[^\\]]+)\\]\\([^)]*\\) \\| `v?(?<from>[0-9][^`]*)` \\| `v?(?<to>[0-9][^`]*)` \\|$")]
  | first // empty;

def distinct: reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end);

# The body also quotes upstream release notes, so a line from there can add an
# update but never hide one, and the PR is rated by its riskiest update.
def updates:
  [.body // "" | body_updates] | distinct | map(. + {semver: semver_change(.from; .to)});

# The part of a Dependabot body that Dependabot writes itself: everything before
# the first <details>, where the quoted release notes, changelogs and commits
# begin.
def own_text: .body // "" | .[:(index("<details>") // length)];

# The updates Dependabot itself names: the title, and in its own text the table
# and the first "Updates" line. A fix is read only from these, since a quoted
# line could otherwise claim one. Later "Updates" lines sit between quoted
# blocks and are left out, which can miss a fix but never invent one.
def own_updates: [(bump // empty | {package, from, to}), (own_text | body_updates)] | distinct;

# The npm scopes ("@opentelemetry") a PR takes to a new major.
def major_scopes:
  [(.bump // empty), .updates[] | select(.semver == "major") | .package
    | select(startswith("@")) | split("/")[0]] | unique;

def severity_rank: {critical: 4, high: 3, medium: 2, low: 1}[. // ""] // 0;

# A version as a key that sorts like the version, four-part Ruby versions
# included. A pre-release sorts below its release.
def version_key:
  ltrimstr("v") | split("+")[0] | split("-") as $parts
  | ($parts[0] | split(".") | map(tonumber? // 0)) as $n
  | ($n + [0, 0, 0, 0, 0, 0])[:6] + [if ($parts | length) > 1 then 0 else 1 end];

# GitHub writes an alert's vulnerable range as comparators joined by commas:
# "< 1.1.16", ">= 2.0.0, < 2.1.5". A range that cannot be read contains
# nothing, so an alert without one never counts as fixed.
def in_range($range):
  version_key as $v
  | ($range // "" | split(",") | map(gsub("^\\s+|\\s+$"; "")
      | [capture("^(?<op><=|>=|<|>|=)?\\s*v?(?<ver>[0-9][^ ]*)$")] | first)) as $cmp
  | ($cmp | length) > 0 and all($cmp[];
      . != null and ((.ver | version_key) as $b
        | {"<": ($v < $b), "<=": ($v <= $b), ">": ($v > $b), ">=": ($v >= $b), "=": ($v == $b)}[.op // "="]));

# The directory of an alert's manifest, as Dependabot names it: "/" for
# package-lock.json, "/app" for app/Gemfile.lock.
def manifest_dir: if . == null then null else "/" + (split("/")[:-1] | join("/")) end;

# The directory a Dependabot PR updates. The title names any directory but the
# root ("bump x from 1.0 to 1.1 in /app"), and a group's body names its one
# directory. A group across several directories has none, so on its own it
# fixes no alert.
def pr_directory:
  if .title | test("across [0-9]+ directories") then null
  else ([.title | capture(" in (?<d>/[^ ]*)( |$)")] | first | .d)
    // ([own_text | capture("updates? in the (?<d>/[^ ]*) directory")] | first | .d)
    // "/"
    | if . == "/" then . else rtrimstr("/") end
  end;

# Whether one of the updates takes an alert's package from inside its vulnerable
# range to outside it.
def moved_out($a; $updates):
  any($updates[]; .package == $a.package
    and (.from | in_range($a.vulnerable)) and (.to | in_range($a.vulnerable) | not));

# The open alerts a PR fixes, per package, with their numbers: one of its
# updates moves the package out of the vulnerable range, in the alert's directory.
def fixed_alerts($dir; $updates; $alerts):
  [$alerts[] | . as $a
    | select($dir != null and ($a.manifest | manifest_dir) == $dir and moved_out($a; $updates))]
  | group_by(.package)
  | map({package: .[0].package, severity: (max_by(.severity | severity_rank) | .severity), count: length,
         alerts: (map(.number) | sort)})
  | sort_by(-(.severity | severity_rank), .package);

# The packages with a critical or high alert that no open Dependabot PR fixes,
# so a fix for them has to come from kogut. The input is the Dependabot PRs as
# dependabot_pr judged them, and an alert is covered only when its number is in
# one of their fixes[], so one rule decides both this and the cooldown. A PR that
# only names a package, moves it within the vulnerable range or updates another
# directory covers nothing, and neither does a group across several
# directories, which names no directory. An alert without a number is never
# covered.
def uncovered_packages($alerts):
  [.[].fixes[].alerts[] | select(. != null)] as $fixed
  | [$alerts[] | select(.severity | IN("critical", "high"))
      | select(.number | IN($fixed[]) | not) | .package]
  | unique;

# The metadata Dependabot writes at the end of its commit message:
#   ---
#   updated-dependencies:
#   - dependency-name: x
#     dependency-type: direct:development
#     update-type: version-update:semver-patch
#   ...
#   Signed-off-by: dependabot[bot] <support@github.com>
# Returns the entries, or null unless the message has exactly one such block, at
# its end, holding nothing but the fields Dependabot writes. So text quoted
# higher up cannot add to it or pass for it, and a format kogut does not know
# reads as nothing.
def commit_metadata:
  (. // "" | split("\n") | map(rtrimstr("\r"))) as $l
  | [$l | to_entries[] | select(.value == "updated-dependencies:") | .key] as $at
  | if $at == [] or $l[$at[0] - 1] != "---" then null
    else
      ([$l | to_entries[] | select(.key > $at[0] and .value == "...") | .key] | first) as $end
      | if $end == null or any($l[$end + 1:][]; (test("^\\s*$") or startswith("Signed-off-by: ")) | not) then null
        else
          reduce $l[$at[0] + 1:$end][] as $line ([];
            if . == null then null else
              ([$line | capture("^(?<lead>- |  )(?<key>dependency-name|dependency-version|dependency-type|update-type|dependency-group): (?<value>.*)$")] | first) as $c
              | if $c == null then null
                elif $c.lead == "- " and $c.key == "dependency-name" then . + [{($c.key): $c.value}]
                elif $c.lead == "  " and length > 0 then .[-1] += {($c.key): $c.value}
                else null end
            end)
          | if . == [] then null else . end
        end
    end;

# The merge gate. A PR is ready only when nothing below applies; the model may
# hold a ready PR back, but never merges past a blocker. split_majors adds the
# one blocker that needs the other PRs, and sets ready_to_merge.
# The cooldown guards against a hostile release, which is usually caught and
# pulled within days. A PR that fixes an alert at cooldown_skip_severity or
# worse skips it: there the known vulnerability is the greater risk. Without
# the setting, every PR waits.
def dependabot_pr($required; $alerts; $p):
  checks as $c
  | checks_state($c) as $state
  | (.createdAt | days_since) as $age
  | bump as $bump
  | updates as $updates
  | ([($bump // empty), $updates[] | .semver] | max_by(semver_rank)) as $semver
  | pr_directory as $dir
  | fixed_alerts($dir; own_updates; $alerts) as $fixes
  | ($p.cooldown_skip_severity | severity_rank) as $skip
  | ($skip > 0 and any($fixes[]; (.severity | severity_rank) >= $skip)) as $urgent
  | ($age < $p.cooldown_days and ($urgent | not)) as $held
  | {
      number, title, url,
      branch: .headRefName,
      # The commit the gate judged; a merge must land exactly this one.
      head: .headRefOid,
      age_days: $age,
      # Read by the auto-merge rule below.
      head_commit: {authors: (.head_authors // []), updates: (.head_message | commit_metadata)},
      # A run started on the branch has the repository's secrets, which
      # Dependabot's own runs do not, so it waits for the cooldown like a merge.
      in_cooldown: $held,
      # When the cooldown ends, while it holds the PR back.
      cooldown_ends: (if $held then (.createdAt | fromdateiso8601) + $p.cooldown_days * 86400 | todate else null end),
      bump: $bump,
      updates: $updates,
      semver: $semver,
      directory: $dir,
      fixes: $fixes,
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
        (if $held then "younger than the \($p.cooldown_days)-day cooldown" else empty end),
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

# The same update in several repositories: one package taken to one version by
# Dependabot PRs in more than one of them. Its release notes are the same
# everywhere, so the model reads and judges them once, and each repository's
# merge is still a call of its own. It is a reporting aid and never a reason to
# merge: every PR keeps the gate's verdict on it alone. A PR whose title names
# its update carries that one only, since any other "Updates" line in its body
# comes from quoted release notes; a group carries the updates its body lists.
# `from` and `semver` are this update's in the PR, and `pr_semver` is the PR's
# riskiest change, which decides --major. The input is the digest's repositories.
def shared_updates:
  [.[] | select(.error == null) | .name as $repo | .dependabot_prs[] | . as $pr
    | (if .bump then [.bump] else .updates end)[]
    | {package, to,
       pr: (($pr | {repo: $repo, number, title, url, directory}) + {from, semver}
         + ($pr | {pr_semver: .semver, ready_to_merge, blockers, in_cooldown, cooldown_ends}))}]
  | group_by([.package, .to])
  | map(select(map(.pr.repo) | unique | length > 1)
      | {package: .[0].package, to: .[0].to,
         repos: (map(.pr.repo) | unique),
         prs: (map(.pr) | unique_by([.repo, .number]))})
  | sort_by(.package, (.to | version_key));

# GitHub names the same App three ways: "app/<slug>" for a PR's author,
# "<slug>[bot]" for a commit's and "<slug>" for a comment's.
def is_app($app): IN($app, "\($app)[bot]", "app/\($app)");

# Whether kogut may merge a PR with nobody watching: the one tier the owner agreed
# to on 2026-11-03. A patch to a dev dependency, by the title and by Dependabot's
# own metadata, from a head commit only Dependabot wrote, past the full cooldown,
# onto a default branch that is not red. Every reason not to is listed, and
# whatever cannot be read counts as a reason. A fix for a high alert skips the
# cooldown in the gate but not here: the cooldown is the only guard this tier has
# against a hostile release, because nobody reads the prompt. $red names the red
# workflows of the default branch, without Dependabot's own runs.
def auto_merge_rule($p; $red):
  (.head_commit.updates) as $u
  | (.age_days // -1) as $age
  | ($p.cooldown_days | if type == "number" then . else null end) as $cooldown
  | ($cooldown != null and $age >= $cooldown) as $old_enough
  | ((.blockers // []) | map(select(startswith("younger than") | not))) as $others
  | [
      (if ($p.auto_merge | if type == "object" then .enabled else null end) != true then "auto-merge is off" else empty end),
      (if $red != [] then "the default branch is red: \($red | join(", "))" else empty end),
      (if .ready_to_merge == true then empty
       elif $others != [] then "not ready: \($others | join("; "))"
       elif $old_enough then "not ready"
       else empty end),
      (if .semver != "patch" then "a \(.semver // "unknown") update, not a patch" else empty end),
      (if .title // "" | test("^[A-Za-z]+\\(deps-dev\\):") then empty else "the title does not say deps-dev" end),
      (if $u == null then "the head commit's Dependabot metadata cannot be read"
       else
         (if all($u[]; .["dependency-type"] == "direct:development") then empty
          else "the metadata names a dependency that is not direct:development" end),
         (if all($u[]; .["update-type"] == "version-update:semver-patch") then empty
          else "the metadata does not call every update a semver patch" end)
       end),
      (if (.head_commit.authors | length) > 0 and all(.head_commit.authors[]; is_app("dependabot")) then empty
       else "the head commit is not only Dependabot's" end),
      (if $old_enough then empty
       else "\($age) day\(if $age == 1 then "" else "s" end) old, and this tier waits the full \($cooldown // "unknown")-day cooldown" end),
      (if (.belongs_with // []) == [] then empty
       else "belongs with \(.belongs_with | map("#\(.)") | join(", "))" end)
    ] as $why
  | {eligible: ($why == []), why: $why};

# The Dependabot command that would get a stuck PR moving, if any. Only what
# Dependabot and the owner wrote after the head commit counts, so anyone else's
# comment, or a Dependabot message they copied, changes nothing. Commands go out
# under the owner's login, because Dependabot refuses them from the App and from
# anyone else without push access. That refusal is not an answer about the PR,
# so it is left out. Once the owner has asked, kogut waits for a new head: one
# command per head, so it never loops.
# Dependabot rebases a conflicting PR on its own, so a conflict counts only
# after a day without a rebase. A comment from Dependabot means it tried. When
# it says someone else edited the PR, recreating it is the way out; any other
# answer is for the owner to read, and a command would only repeat it.
def dependabot_command($owner; $base_at):
  checks as $c
  | (.head_committed_at // .createdAt) as $head_at
  | ([.comments[]? | select(.createdAt > $head_at)] | sort_by(.createdAt)) as $since
  | ([$since[] | select((.author.login | is_app("dependabot"))
      and (.body // "" | contains("only users with push access") | not))] | last) as $note
  | ([$since[] | select(.author.login == $owner
      and (.body // "" | test("^@dependabot (rebase|recreate)\\s*$")))] | last) as $asked
  | ((now_ts - ($head_at | fromdateiso8601)) / 86400) as $head_age
  | ([$c[] | select(.result | bad_result) | .at // empty] | max) as $failed_at
  | {
      head_committed_at: $head_at,
      dependabot_note: ($note | if . then {at: .createdAt, text: (.body // "" | split("\n")[0] | .[0:200])} else null end),
      asked: ($asked | if . then {command: (.body | capture("^@dependabot (?<c>[a-z]+)").c), at: .createdAt} else null end),
      command: (
        if $asked then null
        elif $note then
          (if $note.body // "" | test("edited by someone other than Dependabot") then
             {name: "recreate", reason: "someone other than Dependabot edited it, so Dependabot will not rebase it"}
           else null end)
        elif .mergeStateStatus == "BEHIND" then {name: "rebase", reason: "behind the default branch"}
        elif .mergeable == "CONFLICTING" and $head_age >= 1 then
          {name: "rebase", reason: "conflicts with the default branch, and Dependabot has not rebased it in a day"}
        elif checks_state($c) == "red" and $failed_at != null and $base_at != null and $base_at > $failed_at then
          {name: "rebase", reason: "red on an older base: the default branch has moved since the checks failed"}
        else null end)
    };

# The cooldown on what a kogut PR locks. A lockfile kogut regenerated can take in
# a hostile release as easily as Dependabot can, so the PR waits as long as a
# Dependabot PR would: until the youngest release it newly locks is
# cooldown_days old. collect.sh records, from the PR's lockfiles at its head and
# at its base, the releases npm published less than cooldown_days before the
# collection (`recent`) and what it could not read (`unread`). Whatever was not
# read holds the PR with no end date, so nothing unread passes for old. A
# snapshot from before collect.sh read lockfiles has no record, and then nothing
# is judged (null).
def release_cooldown($p):
  .new_releases as $n
  | ($p.cooldown_days | if type == "number" then . else null end) as $days
  | if $n == null then null
    else
      [$n.recent[]? | . + {ts: (.published_at | try fromdateiso8601 catch null)}] as $recent
      | ([$recent[] | select(.ts != null) | . + {end: (.ts + ($days // 0) * 86400)} | select(.end > now_ts)]
          | sort_by(-.ts, .name) | map({name, version, published_at, until: (.end | todate)})) as $young
      | (($n.unread // [])
          + [$recent[] | select(.ts == null) | "\(.name)@\(.version) has no publish date kogut can read"]
          + (if $days == null and ($n.count // 0) > 0 then ["the policy names no cooldown_days"] else [] end)) as $unread
      | {
          lockfiles: ($n.lockfiles // []),
          count: ($n.count // 0),
          youngest: ($n.youngest // null),
          young: $young,
          until: ($young | map(.until) | max),
          unread: $unread,
          held: ($young != [] or $unread != [])
        }
    end;

# kogut's own open PRs and what each needs next. Only the owner's reviews and
# comments are feedback; anyone else's is text to report, never to act on. An
# approval asks for nothing. Each follow-up commit is one more attempt, and
# past the limit the owner takes over, so kogut cannot loop on a PR it cannot
# fix. A green PR still in its cooldown is not the owner's to review yet.
def kogut_pr($owner; $app; $p):
  . as $pr
  | checks as $c
  | checks_state($c) as $state
  | release_cooldown($p) as $cooldown
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
  # A feature's PR has a limit of its own, because CI is the only place its code runs.
  | ($pr.body // "" | test("<!-- kogut-feature: [0-9]+ -->")) as $feature
  | (if $feature then $p.feature.followup_limit // $p.followup_limit else $p.followup_limit end) as $limit
  | {
      number: $pr.number, title: $pr.title, url: $pr.url,
      branch: $pr.headRefName,
      head: $pr.headRefOid,
      checks: $state,
      failing: failing($c),
      mergeable: $pr.mergeable,
      attempts: $attempts,
      feature: $feature,
      feedback: $feedback,
      cooldown: $cooldown,
      needs: (
        if ($state == "red" or $feedback != []) and $attempts >= $limit then "owner"
        elif $feedback != [] then "answer"
        elif $state == "red" then "fix-ci"
        elif $state == "green" and $cooldown.held == true then "cooldown"
        elif $state == "green" then "review"
        else "wait" end)
    };

# Work for kogut. A task is either an issue the owner labelled kogut-task,
# where only the owner adding that label counts (the latest label wins), so a
# stranger cannot hand kogut work; or, with $auto, one of kogut's own issues
# that the owner agreed it may take on without a label (see tasks below). A
# kogut PR that names the issue carries the task on, and follow-ups take it
# from there. Once kogut has answered on the issue, the task waits until the
# owner speaks again.
def task($owner; $app; $kogut_prs; $auto):
  . as $t
  | ([.labeled[]?] | sort_by(.at) | last) as $label
  | [$kogut_prs[] | select((.body // "") | test("(?i)\\b(closes|fixes|resolves|refs) #\($t.number)\\b")) | .number] as $prs
  | ([.comments[]? | select(.author.login | is_app($app)) | .createdAt] | max) as $answered
  | ([$label.at, (.comments[]? | select(.author.login == $owner) | .createdAt)] | map(select(. != null)) | max) as $asked
  | {
      number, title, url,
      author: .author.login,
      labeled_by: $label.actor,
      auto: $auto,
      # A kogut issue keeps tracking its finding, so a PR refers to it rather than closing it.
      finding: ((.body // "") | contains("<!-- kogut-finding:")),
      prs: $prs,
      needs: (
        if ($auto | not) and $label.actor != $owner then "unauthorized"
        elif $prs != [] then "in-progress"
        elif $answered != null and $answered > $asked then "owner"
        else "start" end)
    };

# The tasks of one repository: the issues the owner labelled, plus kogut's own
# issues that it takes on unasked (agreed with the owner on 2026-10-30): its
# alerts issue while a critical or high alert is in no open Dependabot PR's
# fixes[] (uncovered), and an issue it opened for a major, which means a
# migration. Only issues the App filed itself count, so a stranger cannot forge
# one by copying the marker.
# The feature requests of one repository, as feature.jq decides. Only an open
# issue with the owner's label gets this far; the label is checked again on GitHub
# before anything is posted or opened.
def features($r; $owner; $app; $p):
  ($r.name | IN($p.feature.repos[]?)) as $enabled
  | [$r.prs[] | select(.author.login == "app/\($app)")] as $kprs
  | [($r.features // [])[] | . as $t
      | [$kprs[] | select((.body // "") | test("(?i)\\b(closes|fixes|resolves|refs) #\($t.number)\\b")) | .number] as $prs
      | {number, title, url, prs: $prs, needs: feature_needs($owner; $app; $enabled; $prs)}];

def finding_key: [(.body // "") | capture("<!-- kogut-finding: (?<k>.+?) -->").k][0];

def tasks($r; $owner; $app):
  . as $d
  | [$r.prs[] | select(.author.login == "app/\($app)")] as $kprs
  | [($r.tasks // [])[] | task($owner; $app; $kprs; false)] as $labelled
  | ($d.findings | map({key, value: .}) | from_entries) as $found
  | $labelled + [($r.kogut_issues // [])[]
      | select(.author.login | is_app($app))
      | . as $i | select([$labelled[].number] | index($i.number) | not)
      | finding_key as $k
      | select($k != null and $found[$k] != null)
      | select(($k | startswith("major:")) or ($k == "alerts" and $found[$k].facts.uncovered != []))
      | task($owner; $app; $kprs; true)];

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

# Which branches can go. Squash merges are the norm, so git cannot tell what is
# merged: a branch is prunable only when its tip is exactly the head of a PR from
# this repository merged into the default branch, so a commit added after the
# merge keeps it, and so does a merge into another branch that may never land.
# It must not be the default branch or protected, and no open PR may use it as
# head or base. gh pr list reads 100 open PRs; past that one could go unseen, so nothing
# is prunable. Everything else is kept with its reason: a branch with no PR, an
# unmerged one or one with later commits is the owner's work.
def branch_report($r):
  ($r.branches // {status: "unavailable", items: []}) as $b
  | (($r.prs | length) < 100) as $all_open
  | [$b.items[] | . as $x
      | [$r.prs[] | select(.headRefName == $x.name) | .number] as $open_prs
      | ($open_prs + [$x.prs[] | select(.state == "OPEN") | .number] | unique) as $open_head
      | [$r.prs[] | select(.baseRefName == $x.name) | .number] as $open_base
      | [$x.prs[] | select(.state == "MERGED" and (.cross | not))] as $merged
      | ([$merged[] | select($x.tip != null and .head == $x.tip)] | first) as $match
      | ($match != null and $match.base == $r.repo.default_branch) as $landed
      | if $x.name == $r.repo.default_branch then {name, kind: "default", reason: "the default branch"}
        elif $x.protected then {name, kind: "protected", reason: "protected by a rule"}
        elif $open_head != [] then {name, kind: "open-pr", reason: "head of open PR #\($open_head[0])"}
        elif $open_base != [] then {name, kind: "open-pr", reason: "base of open PR #\($open_base[0])"}
        elif ($all_open | not) then {name, kind: "unread", reason: "over 100 open PRs, so one could use it unseen"}
        elif $landed then {name, tip, pr: $match.number, merged_into: $match.base}
        elif $match then {name, kind: "merged-elsewhere", reason: "PR #\($match.number) merged it into \($match.base), not the default branch"}
        elif $merged != [] then {name, kind: "later-commits", reason: "its tip is not the head of merged PR #\($merged[0].number)"}
        elif $x.prs != [] then {name, kind: "not-merged", reason: "no merged PR from this repository (see PR #\($x.prs[0].number))"}
        else {name, kind: "no-pr", reason: "no PR"} end]
  | {
      status: $b.status,
      prunable: map(select(.kind == null)),
      kept: map(select(.kind != null))
    };

# Open Dependabot alerts, summed by severity and grouped per package, worst
# first: one repository can carry a hundred alerts for a dozen packages. The
# individual alerts stay in the snapshot.
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

# The Node line a pin names: "20", "v20", "20.11.1", or an LTS codename such as
# "lts/iron". Anything else (lts/*, node, stable) names no fixed line.
def pin_line($schedule):
  (. // "" | gsub("^\\s+|\\s+$"; "")) as $p
  | if $p | test("^v?[0-9]+(\\.[0-9]+){0,2}$") then $p | ltrimstr("v") | split(".")[0] | tonumber
    elif ($p | test("^lts/[a-zA-Z]+$")) and $schedule != null then
      ($p[4:] | ascii_downcase) as $name
      | [$schedule | to_entries[] | select((.value.codename // "" | ascii_downcase) == $name)
          | .key | ltrimstr("v") | tonumber?] | first
    else null end;

# The versions a pin can resolve to, as [lowest, highest]: a pin that leaves out
# a part stands for everything under it, so a bare "22" is the whole line.
def pin_span($line):
  999999 as $big
  | (. // "" | gsub("^\\s+|\\s+$"; "") | ltrimstr("v")) as $p
  | if $p | test("^[0-9]+(\\.[0-9]+){0,2}$") then
      ($p | split(".") | map(tonumber)) as $n
      | [($n + [0, 0])[:3], ($n + [$big, $big])[:3]]
    else [[$line, 0, 0], [$line, $big, $big]] end;

# One comparator of an engines range as bounds, or null when it cannot be read.
# Each bound has a side, the version it is at, and whether that version is out.
def comparator_bounds:
  sub("(\\.[xX*])+$"; "") as $t
  | if $t | IN("*", "x", "X") then []
    else ([$t | capture("^(?<op>>=|<=|>|<|=|\\^|~)?v?(?<v>[0-9]+(\\.[0-9]+){0,2})$")] | first) as $c
    | if $c == null then null else
        ($c.v | split(".") | map(tonumber)) as $n
        | ($n | length) as $parts
        | (($n + [0, 0])[:3]) as $at
        # The first version past a partial one: 22 → 23.0.0, 22.1 → 22.2.0.
        | (if $parts == 1 then [$n[0] + 1, 0, 0] elif $parts == 2 then [$n[0], $n[1] + 1, 0] else $at end) as $past
        | ($c.op // "=") as $op
        | if $op == ">=" then [{side: "lo", at: $at, out: false}]
          elif $op == ">" then
            (if $parts == 3 then [{side: "lo", at: $at, out: true}] else [{side: "lo", at: $past, out: false}] end)
          elif $op == "<" then [{side: "hi", at: $at, out: true}]
          elif $op == "<=" then
            (if $parts == 3 then [{side: "hi", at: $at, out: false}] else [{side: "hi", at: $past, out: true}] end)
          elif $op == "=" then
            (if $parts == 3 then [{side: "lo", at: $at, out: false}, {side: "hi", at: $at, out: false}]
             else [{side: "lo", at: $at, out: false}, {side: "hi", at: $past, out: true}] end)
          elif $op == "^" then
            (if $n[0] == 0 then null
             else [{side: "lo", at: $at, out: false}, {side: "hi", at: [$n[0] + 1, 0, 0], out: true}] end)
          else
            [{side: "lo", at: $at, out: false},
             {side: "hi", at: (if $parts == 1 then [$n[0] + 1, 0, 0] else [$n[0], $n[1] + 1, 0] end), out: true}]
          end
      end
    end;

# An engines range as a list of comparator sets joined by ||, or null when any
# part of it cannot be read. A range kogut cannot read is never a conflict.
def engine_sets:
  gsub("(?<op>>=|<=|>|<|=|\\^|~)\\s+"; "\(.op)")
  | split("||") | map(gsub("^\\s+|\\s+$"; ""))
  | map(if . == "" then null
        else [splits("\\s+") | comparator_bounds] | if any(.[]; . == null) then null else add // [] end end)
  | if . == [] or any(.[]; . == null) then null else . end;

# Whether a comparator set leaves any version between $lo and $hi.
def set_allows($lo; $hi):
  ([{at: $lo, out: false}] + map(select(.side == "lo")) | max_by([.at, .out])) as $l
  | ([{at: $hi, out: false}] + map(select(.side == "hi")) | min_by([.at, (.out | not)])) as $h
  | $l.at < $h.at or ($l.at == $h.at and ($l.out | not) and ($h.out | not));

# A line's place in Node's release schedule on the given day.
def node_phase($today):
  if . == null then "unknown"
  elif .end != null and $today >= .end then "eol"
  elif .maintenance != null and $today >= .maintenance then "maintenance"
  elif .lts != null and $today >= .lts then "active"
  elif .start != null and $today >= .start then "current"
  else "unknown" end;

# The Node pin of one repository against the release schedule and its own
# engines. Without the schedule, or when a file could not be read, kogut judges
# nothing (`judged` is false), and an open issue stays open: it does not know
# that the finding is gone. A line on maintenance is worth saying, but only a
# line past its end of life or a pin outside engines is `flagged`. A repository
# without a pin has nothing to judge.
def runtime_signal($schedule):
  (.runtime // {}) as $raw
  | (now_ts | floor | todate | .[0:10]) as $today
  | ($raw.pin | pin_line($schedule)) as $line
  | (if $line == null or $schedule == null then null else $schedule["v\($line)"] end) as $entry
  | ($entry | node_phase($today)) as $phase
  | ($raw.engines // null) as $engines
  | (if $engines == null then null else $engines | engine_sets end) as $sets
  | ($schedule != null and $raw.read_error == false) as $judged
  | (if $line == null or $sets == null then false
     else ($raw.pin | pin_span($line)) as [$lo, $hi] | any($sets[]; set_allows($lo; $hi)) | not end) as $conflict
  | {
      file: ($raw.file // null),
      pin: ($raw.pin // null),
      line: $line,
      phase: $phase,
      since: (if $phase == "eol" then $entry.end elif $phase == "maintenance" then $entry.maintenance else null end),
      active_lts: (if $schedule == null then null
        else [$schedule | to_entries[] | select((.value | node_phase($today)) == "active")
                | .key | ltrimstr("v") | tonumber?] | max end),
      engines: $engines,
      engines_readable: ($engines == null or $sets != null),
      conflict: $conflict,
      judged: $judged,
      flagged: ($judged and ($phase == "eol" or $conflict))
    };

# The repository's Actions secrets by age, oldest first. GitHub gives names and
# dates, never a value or an expiry, so age is all kogut can go by: at
# policy.secret_warn_days a token is old enough that it may have expired, early
# enough to warn before a 90-day one runs out. policy.secret_ignore names the
# ones that do not expire. Without a list (`status` is not "ok") kogut knows
# nothing about them, which says neither that they are fine nor that they are not.
def secrets_signal($p):
  (.secrets // {status: "unavailable", items: []}) as $s
  # A snapshot from before the setting existed still gets the default.
  | ($p.secret_warn_days // 80) as $warn
  | ($p.secret_ignore // []) as $ignore
  | {
      status: $s.status,
      warn_days: $warn,
      items: ([$s.items[]
        | (.updated_at | if . then days_since else null end) as $age
        | {name, updated_at, age_days: $age,
           stale: ($age >= $warn and (.name | IN($ignore[]) | not))}]
        | sort_by(-(.age_days // 0), .name))
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
        # Dependabot's own runs are not the repository's CI: a red one usually
        # means it cannot lift a transitive package. The report still lists them.
        | select(.path | startswith("dynamic/dependabot/") | not)
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
             facts: {by_severity: $r.alerts.by_severity, packages: $serious,
               uncovered: [$serious[] | select(.package | IN($r.alerts.uncovered[])) | .package]}}
          end),
      (if $r.hygiene_issues == [] then empty else
         {key: "hygiene", kind: "hygiene", auto: true,
          title: "Repository hygiene gaps",
          facts: {issues: $r.hygiene_issues}}
       end),
      ($r.runtime | select(.flagged)
        | {key: "runtime:node", kind: "runtime", auto: true,
           title: (if .phase == "eol" then "Runtime: Node \(.line) is past its end of life"
                   else "Runtime: Node \(.line) in \(.file) is outside engines" end),
           facts: {file, pin, line, phase, since, active_lts, engines, conflict}}),
      ([$r.secrets.items[] | select(.stale)] as $stale
        | if $stale == [] then empty else
            {key: "secrets:age", kind: "secrets", auto: true,
             title: (if ($stale | length) == 1
                     then "Secrets: \($stale[0].name) is old enough that it may have expired"
                     else "Secrets: \($stale | length) secrets are old enough that they may have expired" end),
             facts: {warn_days: $r.secrets.warn_days, secrets: ($stale | map({name, updated_at, age_days}))}}
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

# What kogut may run on GitHub to settle a red workflow on the default branch.
# Nothing while a run is going. A failed run on the current head may have its
# failed jobs retried once, while the failures are few: one that keeps coming
# back is not a flake, unless causes.jq reads it as infrastructure, which goes
# on being retried once per run up to policy.infra_retry_limit failures in a row.
# A run on an older commit says nothing about the current one, and GitHub retries
# nothing older than 30 days, so then a workflow that can be started by hand runs
# again at the head, once per head.
def ci_action($w; $runs; $head_sha; $app; $p):
  $w.health as $h | $h.latest as $run
  | [$runs[] | select(.head_sha == $head_sha and (.triggered_by // "" | is_app($app)))] as $mine
  | if $head_sha == null or $run == null or any($runs[]; .status != "completed") then null
    elif $run.head_sha == $head_sha and ($run.created_at | days_since) < 30 then
      (if ($run.run_attempt // 1) >= 2 then null
       elif $h.streak < 3 then {name: "rerun", reason: "failed on the current head and not retried yet"}
       elif $w.cause.kind == "infra" and $h.streak < ($p.infra_retry_limit // 0) then
         {name: "rerun", reason: "failed on infrastructure (\($w.cause.signature)), which a retry can clear"}
       else null end)
    elif $w.dispatchable and $mine == [] then
      {name: "dispatch", reason: (if $run.head_sha == $head_sha then "the last run is too old for GitHub to retry"
        else "the last run was on an older commit, so it says nothing about the current head" end)}
    else null end;

# The rules above, and what holds them back. A refused token fails the same way
# however often it runs. A workflow with a cron and cancel-in-progress kills a
# run started by hand when its schedule fires on the same ref, and GitHub delays
# crons by hours, so no clock says when that is. A day on the default branch does
# not depend on the delay: a daily schedule has covered the head by then, and then
# the run on the head decides. It goes by the head's date, so without one it waits.
def ci_plan($w; $runs; $head_sha; $head_at; $app; $p):
  ci_action($w; $runs; $head_sha; $app; $p) as $action
  | if $w.cause.kind == "credentials" then
      {action: null, held: "the run failed on a refused token (\($w.cause.signature)), and a retry cannot fix that: the owner has to replace it"}
    elif $action.name == "dispatch" and $w.scheduled == true and $w.cancels == true
      and ($head_at == null or ($head_at | days_since) < 1) then
      {action: null, held: "its schedule can still cover this head and would cancel a run started by hand (cancel-in-progress)"}
    else {action: $action, held: null} end;

.policy as $p
| .node_schedule as $node_schedule
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
    | ([.prs[] | select(.author.login == "app/dependabot")
        | dependabot_pr($required; $r.alerts.items // []; $p)
          + dependabot_command($owner; $r.repo.last_commit_at)] | split_majors) as $dependabot
    | {
        name,
        url: .repo.html_url,
        default_branch: .repo.default_branch,
        dependabot_prs: $dependabot,
        other_prs: [.prs[] | select(.author.login | IN("app/dependabot", "app/\($app)") | not) | other_pr($p)],
        kogut_prs: [.prs[] | select(.author.login == "app/\($app)") | kogut_pr($owner; $app; $p)],
        branches: branch_report($r),
        ci_failing: [$active[] | select(.health.streak > 0)
          | ci_plan(.; $r.runs[.id | tostring] // []; $r.repo.head_sha; $r.repo.last_commit_at; $app; $p) as $plan | {
          id, name, path,
          action: $plan.action,
          held: $plan.held,
          cause: (.cause // {kind: "unknown", signature: null}),
          failing_streak: .health.streak,
          of_runs: .health.total,
          last_success_at: .health.last_success_at,
          latest_run: (.health.latest | {id, event, conclusion, created_at, url})
        }],
        ci_flaky: [$active[] | select(.health.streak == 0 and .health.failures > 0) | {
          name, path, failures: .health.failures, of_runs: .health.total
        }],
        # GitHub disables a scheduled workflow after 60 days without activity;
        # one the owner disabled stays as it is.
        workflows_disabled: [.workflows[] | select(.state != "active") | {id, name, path, state,
          action: (if .state == "disabled_inactivity" then
            {name: "enable", reason: "GitHub disabled it after 60 days without activity"} else null end)}],
        alerts: ((.alerts.items | alert_summary)
          + {uncovered: ($dependabot | uncovered_packages($r.alerts.items // []))}),
        runtime: runtime_signal($node_schedule),
        secrets: secrets_signal($p),
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
          (if ($required | length) == 0 and (.required_checks_unread != true) then
            "no required status checks on \(.repo.default_branch): a PR without checks would look green" else empty end),
          (if .repo.allow_auto_merge | not then "auto-merge is disabled" else empty end),
          (if .dependabot_config == false then "no .github/dependabot.yml" else empty end),
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
    | . + {tasks: tasks($r; $owner; $app), features: features($r; $owner; $app; $p)}
    | [.ci_failing[] | select(.path | startswith("dynamic/dependabot/") | not) | .name] as $red
    | .dependabot_prs |= map(. + {auto_merge: auto_merge_rule($p; $red)})
  end]
}
| .shared_updates = (.repos | shared_updates)
