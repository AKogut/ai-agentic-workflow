# The figures behind /kogut progress: what kogut did in the watched repositories
# over a window, next to what the owner did. Code does all the counting, so the
# report never rests on the model's arithmetic.
#
# Input (built by progress.sh): since, until, owner, app, repos (the watched
# names), kogut (search results: every PR and issue the App opened), merged
# (search results: PRs merged since the window began) and figures (per
# repository: the App's comments and the Dependabot alerts, fixed and open).
# With --arg format json the figures are printed, otherwise a markdown report.

def is_app($app): IN($app, "\($app)[bot]", "app/\($app)");
def in_window($since): . != null and .[0:10] >= $since;
def by_severity: reduce .[] as $s ({}; .[$s] += 1);
def count(f): [.[] | select(f)] | length;

def repo_figures($in; $name):
  $in.since as $since | $in.app as $app | $in.owner as $owner
  | [$in.kogut[] | select(.repository.name == $name)] as $mine
  | [$mine[] | select(.__typename == "PullRequest")] as $prs
  | [$mine[] | select(.__typename == "Issue")] as $issues
  | [$in.merged[] | select(.repository.name == $name and (.mergedAt | in_window($since)))] as $merged
  | ([$in.figures[] | select(.name == $name)][0] // {comments: [], alerts: {status: "unavailable", fixed: [], open: []}}) as $f
  | [$f.comments[] | select(.created_at | in_window($since))] as $comments
  | {
      name: $name,
      kogut: {
        # kogut merges only Dependabot PRs; its own fixes are the owner's to merge.
        merged: ($merged | count(.mergedBy.login // "" | is_app($app))),
        prs: {
          opened: ($prs | count(.createdAt | in_window($since))),
          merged: ($prs | count(.mergedAt | in_window($since))),
          closed: ($prs | count(.state == "CLOSED" and (.closedAt | in_window($since)))),
          open: ($prs | count(.state == "OPEN"))
        },
        issues: {
          opened: ($issues | count(.createdAt | in_window($since))),
          # kogut closes an issue once its finding is gone.
          closed: ($issues | count(.state == "CLOSED" and (.closedAt | in_window($since))
            and (.timelineItems.nodes[0].actor.login // "" | is_app($app)))),
          closed_by_owner: ($issues | count(.state == "CLOSED" and (.closedAt | in_window($since))
            and .timelineItems.nodes[0].actor.login == $owner)),
          open: ($issues | count(.state == "OPEN"))
        },
        comments: ($comments | length),
        commands: ($comments | count(.body | startswith("@dependabot ")))
      },
      owner: {
        merged: ($merged | count(.mergedBy.login == $owner)),
        kogut_fixes: ($merged | count(.mergedBy.login == $owner and (.author.login | is_app($app)))),
        dependabot: ($merged | count(.mergedBy.login == $owner and (.author.login | is_app("dependabot")))),
        own: ($merged | count(.mergedBy.login == $owner and .author.login == $owner))
      },
      # The PRs and issues behind the numbers, for the links in the report.
      links: {
        kogut_merged: [$merged[] | select(.mergedBy.login // "" | is_app($app)) | .url],
        fix_prs: [$prs[] | select(.createdAt | in_window($since)) | .url],
        issues: [$issues[] | select(.createdAt | in_window($since)) | .url]
      },
      alerts: {
        status: $f.alerts.status,
        fixed: ([$f.alerts.fixed[] | select(.fixed_at | in_window($since)) | .severity] | by_severity),
        open: ([$f.alerts.open[] | .severity] | by_severity)
      }
    };

# Sums the numbers of several figures objects of the same shape.
def plus($b):
  if type == "object" then
    . as $a | reduce (($a + $b) | keys_unsorted[]) as $k ({};
      .[$k] = (if ($a | has($k)) and ($b | has($k)) then ($a[$k] | plus($b[$k])) else ($a[$k] // $b[$k]) end))
  elif type == "number" then . + $b
  else . end;

def figures:
  . as $in
  | [$in.repos[] as $name | repo_figures($in; $name)] as $repos
  | {
      since, until, repos: $repos,
      totals: (reduce ($repos[] | {kogut, owner, alerts: (.alerts | {fixed, open})}) as $r (null;
        if . == null then $r else plus($r) end))
    };

# Markdown.
def plural($n; $word): "\($n) \($word)\(if $n == 1 then "" else "s" end)";
def day: strptime("%Y-%m-%d") | mktime | strftime("%d %b %Y") | sub("^0"; "");
def severities($o): [("critical", "high", "medium", "low") as $s | select(($o[$s] // 0) > 0) | "\($o[$s]) \($s)"]
  | if . == [] then "none" else join(", ") end;
def total($o): [$o[]] | add // 0;
def serious($o): "\($o.critical // 0) / \($o.high // 0)";

def markdown:
  .totals as $t
  | "## kogut progress, \(.since | day) to \(.until | day)",
    "",
    ("kogut merged \(plural($t.kogut.merged; "Dependabot PR")), opened \(plural($t.kogut.prs.opened; "fix PR"))"
      + ([($t.kogut.prs.merged | select(. > 0) | "\(.) merged by the owner"),
          ($t.kogut.prs.closed | select(. > 0) | "\(.) closed unmerged"),
          ($t.kogut.prs.open | select(. > 0) | "\(.) open now")] | if . == [] then "" else " (\(join(", ")))" end)
      + ", filed \(plural($t.kogut.issues.opened; "issue"))"
      + ($t.kogut.issues.closed | if . > 0 then " and closed \(.) once the finding was gone" else "" end)
      + ", and wrote \(plural($t.kogut.comments; "comment"))"
      + ($t.kogut.commands | if . == 1 then ", 1 of them a command to Dependabot"
          elif . > 1 then ", \(.) of them commands to Dependabot" else "" end) + "."),
    "",
    "Dependabot alerts closed: \(total($t.alerts.fixed)) (\(severities($t.alerts.fixed))). Open now: \(severities($t.alerts.open)).",
    "",
    ("The owner merged \(plural($t.owner.merged; "PR")): \($t.owner.kogut_fixes) of kogut's fixes,"
      + " \($t.owner.dependabot) from Dependabot and \($t.owner.own) of their own."),
    "",
    "| Repository | kogut merged | Fix PRs (merged) | Issues opened / closed | Comments | Alerts closed | Critical / high open | Owner merged (kogut's fixes) |",
    "|---|---|---|---|---|---|---|---|",
    (.repos[]
      | (if .alerts.status == "ok" then total(.alerts.fixed) | tostring else "n/a" end) as $closed
      | (if .alerts.status == "ok" then serious(.alerts.open) else "n/a" end) as $open
      | "| \(.name) | \(.kogut.merged) | \(.kogut.prs.opened) (\(.kogut.prs.merged)) | \(.kogut.issues.opened) / \(.kogut.issues.closed) | \(.kogut.comments) | \($closed) | \($open) | \(.owner.merged) (\(.owner.kogut_fixes)) |");

figures | if $format == "json" then . else markdown end
