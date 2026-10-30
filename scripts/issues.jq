# The issue policy: given one repository's findings (from signals.jq), the
# open issues the kogut App filed there and the model's diagnoses, decide what
# happens to each issue. scripts/issues.sh carries the plan out; tests/run.sh
# checks it. Included as a module, so it holds definitions only.

# Facts that kogut rewrites on every run, in markdown.
def facts:
  if .kind == "ci" then .facts as $f
    | "- Workflow: `\($f.workflow)` (`\($f.path)`)\n"
    + "- Failed runs in a row on the default branch: \($f.failing_streak) of the last \($f.of_runs)\n"
    + "- Last success: \(if $f.last_success_at then $f.last_success_at[0:10] else "none in the window" end)\n"
    + "- Latest run: [\($f.latest_run.conclusion) on \($f.latest_run.created_at[0:10])](\($f.latest_run.url))"
  elif .kind == "workflow-disabled" then
    "- Workflow: `\(.facts.workflow)` (`\(.facts.path)`)\n- State: `\(.facts.state)`"
  elif .kind == "alerts" then
    (.facts.by_severity | "- Open alerts: \(.critical // 0) critical, \(.high // 0) high, \(.medium // 0) medium, \(.low // 0) low\n")
    + ([.facts.packages[] | "- **\(.package)**: \(.severity), \(.count) alert\(if .count > 1 then "s" else "" end), "
        + (if .patched == [] then "no fixed version yet" else "fixed in \(.patched | join(" / "))" end)
        + " · [worst alert](\(.url))"] | join("\n"))
  elif .kind == "hygiene" then [.facts.issues[] | "- \(.)"] | join("\n")
  elif .kind == "major" then [.facts.prs[] | "- #\(.number): \(.versions | join(", "))"] | join("\n")
  else "" end;

# The issue body: the model's diagnosis, the facts, a footer, and the key that
# ties the issue to its finding.
def body($diagnosis; $today; $homepage):
  (if ($diagnosis // "" | test("\\S")) then ($diagnosis | sub("\\s+$"; "")) + "\n\n" else "" end)
  + "<!-- kogut-facts -->\n**Facts**, as of \($today):\n" + facts
  + "\n\n---\n<sub>Opened by [kogut](\($homepage)), the maintenance agent for this portfolio. "
  + "It updates this issue on every run and closes it once the finding is gone.</sub>\n"
  + "<!-- kogut-finding: \(.key) -->";

# The diagnosis already in an issue body: everything above the facts.
def diagnosis:
  if contains("<!-- kogut-facts -->") then split("<!-- kogut-facts -->")[0] | sub("\\s+$"; "") else "" end;

# The comment an issue is closed with, from its key.
def closing($today):
  (.key | index(":")) as $i
  | (if $i then .key[:$i] else .key end) as $kind
  | (if $i then .key[$i + 1:] else "" end) as $what
  | "On \($today) kogut no longer reports this: "
  + (if $kind == "ci" then "`\($what)` is no longer failing on the default branch."
     elif $kind == "workflow-disabled" then "`\($what)` is enabled again."
     elif $kind == "alerts" then "no critical or high Dependabot alerts are open."
     elif $kind == "hygiene" then "no hygiene gaps are left."
     elif $kind == "major" then "no open Dependabot PR takes `\($what)` to a new major."
     else "the finding is gone." end)
  + " Closing.";

# $d: the repository's digest; $issues: [{number, title, url, body, key}] for
# open issues the App filed with the kogut label; $texts: {slug: diagnosis}.
# One step per finding and per orphaned issue:
#   open    a finding without an issue: `auto`, or the model wrote a diagnosis
#   update  the issue would read differently: new facts, title or diagnosis
#   keep    the issue already reads as it should
#   skip    a major the model wrote nothing about
#   close   an issue whose finding is gone
def plan($d; $issues; $texts; $today; $home):
  [ ($d.findings[] as $f
      | ([$issues[] | select(.key == $f.key)][0]) as $i
      | ($texts[$f.slug] // null) as $t
      | if $i then
          ($f | body($t // ($i.body | diagnosis); $today; $home)) as $b
          | if $b == $i.body and $f.title == $i.title
            then {action: "keep", number: $i.number, title: $i.title, url: $i.url}
            else {action: "update", number: $i.number, title: $f.title, body: $b, url: $i.url, slug: $f.slug, text: ($t != null)} end
        elif $f.auto or $t != null then
          {action: "open", title: $f.title, body: ($f | body($t; $today; $home)), key: $f.key, slug: $f.slug, text: ($t != null)}
        else {action: "skip", title: $f.title, key: $f.key, slug: $f.slug} end),
    ($issues[] | select(.key != null) | . as $i
      | select([$d.findings[].key] | index($i.key) | not)
      | {action: "close", number, title, url, comment: closing($today)})
  ];
