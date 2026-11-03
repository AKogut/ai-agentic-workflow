# The daily digest: one report per repository, rendered from the output of
# signals.jq with no judgement, so it needs no model. scripts/digest.sh sends it.
# Output: [{name, status, text}], where status is the colour of the report.
#
# Red and green mean what they mean in a /kogut report: red when the default
# branch is red or there is a critical or high alert, yellow when something
# waits for the owner or for a /kogut run, green otherwise. A Node line on
# maintenance is only mentioned; past its end of life or outside engines, it
# makes the report yellow. PRs and issues show as numbers, without their titles,
# so no text from anyone else reaches a channel.

def link: "[#\(.number)](\(.url))";
def links: map(link) | join(", ");
def line($label; $text): if $text == "" then empty else "**\($label):** \($text)" end;
def list($label; $items):
  if $items == [] then empty else "**\($label):**", ($items[] | "- \(.)") end;
def plural($n; $word): "\($n) \($word)\(if $n == 1 then "" else "s" end)";

def cooldown_only: .blockers != [] and all(.blockers[]; startswith("younger than"));

def report:
  if .error then {name, status: "yellow", text: "Could not read this repository: \(.error)"}
  else
    # Dependabot's own runs are not the repository's CI, as in findings.
    [.ci_failing[] | select(.path | startswith("dynamic/dependabot/") | not)] as $red
    | [.dependabot_prs[] | select(.ready_to_merge)] as $ready
    | [.dependabot_prs[] | select(cooldown_only)] as $waiting
    | [.dependabot_prs[] | select((.ready_to_merge | not) and (cooldown_only | not))] as $stuck
    | [.kogut_prs[] | select(.needs | IN("review", "owner"))] as $for_owner
    | [.kogut_prs[] | select(.needs | IN("fix-ci", "answer"))] as $for_kogut
    # kogut's own issues show as their alerts and majors; these are the owner's.
    | [.tasks[] | select((.auto | not) and .needs == "start")] as $tasks
    | [.tasks[] | select((.auto | not) and .needs == "owner")] as $answered
    | [.other_prs[] | select(.stale)] as $stale
    | [.workflows_disabled[] | select(.action != null)] as $disabled
    | (.alerts.by_severity // {}) as $s
    | (.runtime // {}) as $rt
    | ([(if $rt.phase == "eol" then "past its end of life"
         elif $rt.phase == "maintenance" then "on maintenance" else empty end),
        (if $rt.conflict and $rt.judged then "outside `engines` `\($rt.engines)`" else empty end)] | join(", ")) as $node
    | ([("critical", "high", "medium", "low") as $k | select(($s[$k] // 0) > 0) | "\($s[$k]) \($k)"] | join(", ")) as $alerts
    | [
        line("Ready to merge"; $ready | map(link + (if .semver == "major" then " (major)" else "" end)) | join(", ")),
        list("Stuck"; $stuck | map("\(link): \(.blockers | join("; "))")),
        line("kogut PRs waiting for you"; $for_owner | links),
        line("kogut PRs with work for kogut"; $for_kogut | links),
        line("Tasks waiting for kogut"; $tasks | links),
        line("Tasks waiting for you"; $answered | links),
        list("Other PRs gone stale"; $stale | map("\(link)\(if .draft then " (draft)" else "" end), \(.age_days | floor) days old")),
        list("CI red"; $red | map("[\(.name)](\(.latest_run.url)), \(.failing_streak) in a row")),
        line("Turned off by GitHub"; $disabled | map(.name) | join(", ")),
        line("Alerts"; if $alerts == "" then "" else "[\($alerts)](\(.url)/security/dependabot)" end),
        line("Hygiene"; .hygiene_issues | join("; ")),
        line("Node"; if $node == "" then "" else "`\($rt.pin)` in `\($rt.file)`, \($node)."
          + (if $rt.active_lts then " Active LTS: \($rt.active_lts)." else "" end) end),
        line("In cooldown"; if $waiting == [] then "" else plural($waiting | length; "PR") end),
        line("Merged branches to prune"; (.branches.prunable // []) | length | if . == 0 then "" else tostring end)
      ] as $lines
    | {
        name,
        status: (
          if $red != [] or (($s.critical // 0) + ($s.high // 0)) > 0 then "red"
          elif ($ready + $stuck + $for_owner + $for_kogut + $tasks + $answered + $stale + $disabled) != []
            or .hygiene_issues != [] or $rt.flagged == true then "yellow"
          else "green" end),
        text: (["*Daily digest: read-only, nothing was changed.*"]
          + (if ($lines | map(select(
                 (startswith("**In cooldown") or startswith("**Merged branches")
                   or (startswith("**Node") and $rt.flagged != true)) | not))) == []
             then ["Nothing needs you."] else [] end)
          + $lines | join("\n"))
      }
  end;

[.repos[] | report]
