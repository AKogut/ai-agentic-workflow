# Which work to start now, so several agents can run at once without getting in
# each other's way. At most one piece of work per repository, because two writers
# in one repository would fight over its lockfile and its base, and at most
# policy.parallel_agents in all, because each agent spends real tokens from the
# subscription. A repository on hold, or with a fix already in a worktree, waits.
#
# Input: {repos (the digest's), holds: {repo: why}, busy: {repo: [slugs]}, limit}.
# Output: {run: [...], waiting: [...]}, each entry with repo, number, lane (task
# or feature), needs and url, and in waiting also why. The owner's work comes
# before kogut's own issues, and older issues first.
def work:
  [(.tasks // [])[] | select(.needs == "start") | {lane: "task", needs, number, url, auto}]
  + [(.features // [])[] | select(.needs | IN("plan", "build")) | {lane: "feature", needs, number, url, auto: false}]
  | sort_by(.auto, .number);

.holds as $holds | .busy as $busy | .limit as $limit
| [.repos[] | select(.error | not) | .name as $n | work | map(. + {repo: $n})] as $by_repo
| [$by_repo[] | select(. != []) | .[0].repo as $repo
    | if $holds[$repo] then map(. + {why: "on hold"})[]
      elif ($busy[$repo] // []) != [] then map(. + {why: "a fix is in progress: \($busy[$repo] | join(", "))"})[]
      else (.[0] + {why: null}), (.[1:][] | . + {why: "one piece of work per repository"}) end] as $all
| [$all[] | select(.why == null)] | sort_by(.auto, .number) as $free
| {
    run: ($free[:$limit] | map(del(.why, .auto))),
    waiting: (($free[$limit:] | map(. + {why: "over the limit of \($limit) at once"})) + [$all[] | select(.why != null)] | map(del(.auto)))
  }
