# The daily summary: one short message about every repository, for the optional
# summary channel. Like digest.jq it renders the output of signals.jq with no
# judgement, and it picks items the way digest.jq does, so the summary and the
# repository reports agree. scripts/digest.sh sends it, after the reports.
#
# Input: what digest.jq reads, signals.jq's output plus holds, {repo: why}, and
# auto_merged, today's records from auto-merge.sh. $reports is digest.jq's
# output, and the summary takes the worst colour among the reports.
# Output: {status, text}, one line per item, each naming its repository, with a
# link. PRs and issues show as numbers, never their titles.
#
# - Waits for you: kogut's PRs for the owner to review or take over, Dependabot
#   PRs ready by the gate, answered tasks and feature plans, and what only the
#   owner can do: replace a token a workflow was refused, rotate an old secret.
# - Red: red workflows on the default branch (Dependabot's own runs aside), as
#   in digest.jq, critical and high alerts, and PRs with red checks that the
#   cooldown list does not already show.
# - In cooldown: each PR the cooldown holds and when it is free, earliest first,
#   with whatever else holds it. A kogut PR waiting for what its lockfile locks
#   is here too, since it is not the owner's to review yet.
# - Auto-merged today: what auto-merge.sh merged, or refused, today.
# - On hold, and the repositories that could not be read.

def link: "[#\(.number)](\(.url))";
def section($title; $items): if $items == [] then empty else "**\($title)**", ($items[] | "- \(.)") end;
def utc: .[0:16] | sub("T"; " ") + " UTC";
def red_cause: if (.cause.signature // null) == null then "" else ": \(.cause.kind) (\(.cause.signature))" end;

. as $root
| [.repos[] | select(.error | not)] as $read
| ($read | map({key: .name, value: .url}) | from_entries) as $urls
| [.repos[].name] as $names

| [$read[] | .name as $n | .url as $u
    | ([.kogut_prs[] | select(.needs == "review") | "\($n) \(link): kogut's PR, green, for you to review and merge"]
     + [.kogut_prs[] | select(.needs == "owner") | "\($n) \(link): kogut's PR, past its follow-up limit, so it is yours"]
     + [.dependabot_prs[] | select(.ready_to_merge) | "\($n) \(link): ready to merge"
         + (if .semver == "major" then " (major)" else "" end)
         + (if .auto_merge.eligible == true then ", in the auto-merge tier" else "" end)]
     + [.tasks[] | select((.auto | not) and .needs == "owner") | "\($n) \(link): kogut answered the task, your turn"]
     + [(.features // [])[] | select(.needs == "owner") | "\($n) \(link): a feature plan waits for your approval"]
     + [.ci_failing[] | select(.cause.kind == "credentials")
         | "\($n) [\(.name)](\(.latest_run.url)): a token was refused (\(.cause.signature)), and only you can replace it"]
     + [(.secrets.items // [])[] | select(.stale)
         | "\($n) [\(.name)](\($u)/settings/secrets/actions): a secret \(.age_days) days old, so it may have expired"])[]
  ] as $waits

| [$read[] | .name as $n | .url as $u | (.default_branch // "the default branch") as $b | (.alerts.by_severity // {}) as $s
    | ([.ci_failing[] | select(.path | startswith("dynamic/dependabot/") | not)
         | "\($n) [\(.name)](\(.latest_run.url)): red on \($b), \(.failing_streak) in a row\(red_cause)"]
     + [[("critical", "high") as $k | select(($s[$k] // 0) > 0) | "\($s[$k]) \($k)"]
         | select(. != []) | "\($n) [\(join(", ")) alerts](\($u)/security/dependabot)"]
     + [.dependabot_prs[] | select(.checks == "red" and .in_cooldown != true) | "\($n) \(link): Dependabot's PR, checks red"]
     + [.kogut_prs[] | select(.checks == "red" and .needs != "owner") | "\($n) \(link): kogut's PR, checks red"])[]
  ] as $red

| ([$read[] | .name as $n
    | (.dependabot_prs[] | select(.in_cooldown == true)
        | [.blockers[] | select(startswith("younger than") | not)] as $also
        | {at: (.cooldown_ends // "~"),
           text: ("\($n) \(link): free \(if .cooldown_ends then "from \(.cooldown_ends | utc)" else "after the cooldown" end)"
             + (if $also == [] then "" else "; also \($also | join("; "))" end))}),
      # What could not be dated holds a kogut PR with no end, as in digest.jq.
      (.kogut_prs[] | select(.needs == "cooldown")
        | (if (.cooldown.unread // []) != [] then null else .cooldown.until // null end) as $until
        | {at: ($until // "~"),
           text: ("\($n) \(link): kogut's PR, "
             + (if $until then "free from \($until | utc)" else "held until every release it locks can be dated" end))})]
  | sort_by(.at) | map(.text)) as $cooldown

# Today's records, the latest for each PR, since a later run can settle a refusal.
| ([($root.auto_merged // [])[] | select(.repo | IN($names[]))]
  | group_by([.repo, .pr]) | map(last)
  | map((if $urls[.repo] then "\(.repo) [#\(.pr)](\($urls[.repo])/pull/\(.pr))" else "\(.repo) #\(.pr)" end)
      + (if .outcome == "merged" then ": merged" else ": not merged, \(.reason // "no reason recorded")" end))) as $auto
| ([($root.auto_merged // [])[] | select((.repo | IN($names[])) and .outcome == "merged")] != []) as $changed

| [$names[] as $n | ($root.holds // {})[$n] // empty
    | "\($n): \(ltrimstr("on hold") | ltrimstr(", ") | ltrimstr(" "))"] as $held
| [.repos[] | select(.error) | "\(.name): could not be read, and its channel says why"] as $unread

| ($names | length) as $count
| {
    status: ([$reports[].status] as $all
      | if any($all[]; . == "red") then "red" elif any($all[]; . == "yellow") then "yellow" else "green" end),
    text: ([
        "*Daily summary of \($count) repositor\(if $count == 1 then "y" else "ies" end)"
          + (if (.generated_at // "") == "" then "" else ", \(.generated_at[0:10])" end)
          + (if $changed then ": the merges below are all kogut changed.*" else ": read-only, nothing was changed.*" end),
        (if $waits == [] and $red == [] then "Nothing waits for you, and nothing is red."
         elif $waits == [] then "Nothing waits for you."
         else empty end),
        section("Could not read"; $unread),
        section("Waits for you"; $waits),
        section("Red"; $red),
        section("In cooldown"; $cooldown),
        section("Auto-merged today"; $auto),
        section("On hold"; $held)
      ] | join("\n"))
  }
