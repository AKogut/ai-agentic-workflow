# Shared helpers for kogut scripts. Sourced, not executed.
# shellcheck shell=bash

KOGUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KOGUT_CONFIG="$KOGUT_ROOT/kogut.config.json"

die() {
  echo "kogut: $*" >&2
  exit 1
}

command -v gh >/dev/null || die "gh is not installed"
command -v jq >/dev/null || die "jq is not installed"
[ -f "$KOGUT_CONFIG" ] || die "missing $KOGUT_CONFIG"

# `gh api` prints the error body on stdout even when it fails, so a plain
# `|| echo fallback` would leave invalid JSON behind. Prints the response, or
# $1 if the request failed.
api_or() {
  local fallback="$1" out
  shift
  if out="$(gh api "$@" 2>/dev/null)"; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$fallback"
  fi
}

kogut_owner() { jq -r '.owner' "$KOGUT_CONFIG"; }

kogut_policy() { jq -r --arg k "$1" '.policy[$k]' "$KOGUT_CONFIG"; }

# Every configured repository name, one per line.
kogut_repos() { jq -r '.repos[].name' "$KOGUT_CONFIG"; }

# Scripts only ever touch the configured repositories, so every name that comes
# in as an argument is checked here first.
kogut_require_repo() {
  jq -e --arg r "$1" 'any(.repos[]; .name == $r)' "$KOGUT_CONFIG" >/dev/null ||
    die "'$1' is not in kogut.config.json (known: $(kogut_repos | paste -sd, -))"
}

# The owner's stop switch, kept outside the repository so a run from any worktree
# sees it (scripts/hold.sh sets it). Prints why a repository is on hold and
# succeeds, or fails when it is not. No file means no hold, and a file that cannot
# be read holds every repository, so a damaged switch cannot fail open.
kogut_hold_file() { echo "${KOGUT_HOLD_FILE:-$HOME/.config/kogut/hold.json}"; }
kogut_held() {
  local file why
  file="$(kogut_hold_file)"
  [ -e "$file" ] || [ -L "$file" ] || return 1
  # shellcheck disable=SC2016 # $r belongs to jq
  if ! why="$(jq -rs --arg r "$1" '
    if length == 1 and (.[0] | type) == "object" and (.[0].repos | type) == "object" then
      .[0].repos[$r] | if . == null then "" else
        "on hold since \(.since // "an unknown date")\(if .reason then ": \(.reason)" else "" end)" end
    else error("not a hold file") end' "$file" 2>/dev/null)"; then
    echo "on hold, because the hold file cannot be read: $file"
    return 0
  fi
  [ -n "$why" ] || return 1
  echo "$why"
}
# For a script that writes on GitHub. It runs before anything else, dry runs
# included, so a dry run never promises what the real call would refuse.
kogut_require_not_held() {
  local why
  if why="$(kogut_held "$1")"; then
    die "$1 is $why. Nothing was done; only the owner lifts a hold (./scripts/hold.sh off $1)"
  fi
}

# A scheduled run starts right after the Mac wakes, before the network is back.
# It waits until GitHub answers whoever reads (policy.read_as): gh's login, or
# the App's key.
kogut_wait_online() {
  local _ as jwt=""
  as="$(kogut_read_as)" || return 1
  if [ "$as" = app ]; then jwt="$(kogut_app_jwt)" || return 1; fi
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ "$as" = app ]; then
      curl -fsS -o /dev/null -H "Authorization: Bearer $jwt" -H 'Accept: application/vnd.github+json' \
        https://api.github.com/app 2>/dev/null && return 0
    else
      gh api rate_limit --silent 2>/dev/null && return 0
    fi
    sleep 30
  done
  return 1
}

# A fresh digest. GitHub works out mergeability when asked, so a first read can
# say UNKNOWN. Arguments: the snapshot's path, then the repositories, if not all.
kogut_settled_digest() {
  local state="$1" digest
  shift
  digest="$(KOGUT_STATE="$state" "$KOGUT_ROOT/scripts/collect.sh" "$@")"
  if jq -e 'any(.repos[].dependabot_prs[]?; .mergeable == "UNKNOWN")' <<<"$digest" >/dev/null; then
    sleep 30
    digest="$(KOGUT_STATE="$state" "$KOGUT_ROOT/scripts/collect.sh" "$@")"
  fi
  printf '%s\n' "$digest"
}

# Local clone of a configured repository, with ~ expanded.
kogut_repo_path() {
  local p
  p="$(jq -r --arg r "$1" '.repos[] | select(.name == $r) | .path' "$KOGUT_CONFIG")"
  echo "${p/#\~/$HOME}"
}

# Default branch of a configured repository: the local clone's origin/HEAD, or
# GitHub's answer when the clone does not record it, read as policy.read_as says.
kogut_default_branch() {
  local dir branch
  dir="$(kogut_repo_path "$1")"
  branch="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  branch="${branch#origin/}"
  if [ -z "$branch" ]; then
    branch="$(kogut_read_env "$1" && gh repo view "$(kogut_owner)/$1" --json defaultBranchRef --jq .defaultBranchRef.name)"
  fi
  echo "$branch"
}

# Scans text on stdin with gitleaks and this project's rules. Prints the
# redacted report and fails when it finds a secret, so nothing kogut writes on
# GitHub can carry one.
kogut_scan() {
  local report
  command -v gitleaks >/dev/null || die "gitleaks is not installed, so nothing can be scanned for secrets"
  if ! report="$(gitleaks stdin --no-banner --redact --config "$KOGUT_ROOT/.gitleaks.toml" 2>&1)"; then
    printf '%s\n' "$report" >&2
    return 1
  fi
}

# The title line of a fix's text file: the PR title, or a follow-up's commit
# message. kogut does not build features unless the owner approved one, so the
# title must use one of the maintenance types of Conventional Commits. The rest of the file,
# after a blank second line, is the PR body or the follow-up's comment.
# Only a feature the owner approved passes "feature" as $2, which also allows feat.
kogut_fix_title() {
  local text="$1" title types='fix|ci|build|chore|docs|test' what="maintenance"
  if [ "${2:-}" = feature ]; then
    types="feat|$types"
    what="feature"
  fi
  local title_re="^($types)(\\([a-z0-9._/-]+\\))?: .+\$"
  [ -s "$text" ] || die "the text is missing: $text"
  title="$(head -n 1 "$text")"
  [[ "$title" =~ $title_re ]] || die "the title must be a $what Conventional Commit (${types//|/, }): $title"
  [ "${#title}" -le 72 ] || die "the title is longer than 72 characters"
  [ -z "$(sed -n 2p "$text")" ] || die "the second line of $text must be blank"
  [ -n "$(tail -n +3 "$text" | tr -d '[:space:]')" ] || die "the body of $text is empty"
  echo "$title"
}

# Stages everything in a fix's worktree and checks it. The change must not be
# empty, and it may touch .github/workflows/ only when $2 is true: a workflow
# on a branch runs with the repository's secrets before review, so the owner
# should see that flag in the prompt. It never touches a .claude/settings.json:
# that file says what an agent may run without asking, kogut's own included, so
# only the owner changes it, by hand. Then the changed lines and the text ($3)
# are scanned with gitleaks. The change is measured from the worktree's HEAD, or
# from $4 when a refresh merged the PR's base into the worktree: then it is what
# the PR holds against that base, because the base's own changes are not the
# fix's to answer for.
kogut_stage() {
  local worktree="$1" workflows="$2" text="$3" from="${4:-HEAD}" changed settings
  git -C "$worktree" add -A
  changed="$(git -C "$worktree" diff --cached --name-only --no-renames "$from")"
  [ -n "$changed" ] || die "the fix changes nothing"
  settings="$(grep -E '(^|/)\.claude/settings(\.local)?\.json$' <<<"$changed" | head -n 1)" || true
  [ -z "$settings" ] || die "the fix changes $settings: what an agent may run is the owner's to set, by hand"
  if grep -q '^\.github/workflows/' <<<"$changed"; then
    [ "$workflows" = true ] || die "the fix changes .github/workflows/: pass --workflows"
  else
    [ "$workflows" = false ] || die "the fix changes no workflow: drop --workflows"
  fi
  { git -C "$worktree" diff --cached --unified=0 "$from"; cat "$text"; } | kogut_scan ||
    die "gitleaks flagged the fix; nothing was sent"
}

# The staged change, for the owner to read before approving: against the
# worktree's HEAD, or against $2, the base a refresh merged in.
kogut_show_diff() {
  local from="${2:-HEAD}"
  git -C "$1" diff --cached --stat "$from"
  echo "--- diff"
  git -C "$1" diff --cached "$from" | awk 'NR <= 400 { print } END { if (NR > 400) print "... " NR - 400 " more lines" }'
}

# Builds a worktree's staged change as a commit on GitHub, on top of the
# worktree's HEAD, and prints the commit's id. The blobs and modes are the
# ones git staged, and GitHub's tree must hash to the staged tree, so the
# commit holds exactly the diff that was shown. Needs GH_TOKEN exported with
# the App's token; no git credentials are involved. With $4, a commit of the
# PR's base branch that was merged into the worktree, the commit is that merge:
# the base is its second parent, so the branch still only moves forward and
# GitHub measures the PR from that commit.
kogut_api_commit() {
  local full="$1" worktree="$2" message="$3" also="${4:-}" entries status path mode sha blob tree staged
  entries="$(mktemp)"
  while IFS= read -r -d '' status && IFS= read -r -d '' path; do
    case "$path" in -* | *$'\n'* | *$'\t'*) die "refusing an unusual path: $path" ;; esac
    if [ "$status" = D ]; then
      read -r mode _ <<<"$(git -C "$worktree" ls-tree HEAD -- "$path")"
      jq -cn --arg p "$path" --arg m "$mode" '{path: $p, mode: $m, type: "blob", sha: null}'
    else
      read -r mode sha _ <<<"$(git -C "$worktree" ls-files -s -- "$path")"
      [ "$mode" != 160000 ] || die "refusing a submodule change: $path"
      if [ -n "$also" ] && [ "$(git -C "$worktree" rev-parse -q --verify "$also:$path" 2>/dev/null || true)" = "$sha" ]; then
        # A file as the merged-in base has it is on GitHub already, and is not sent again.
        blob="$sha"
      else
        blob="$(git -C "$worktree" cat-file blob "$sha" | base64 | tr -d '\n' |
          jq -Rs '{content: ., encoding: "base64"}' |
          gh api -X POST "repos/$full/git/blobs" --input - --jq .sha)"
        [ "$blob" = "$sha" ] || die "GitHub stored $path as $blob, not $sha"
      fi
      jq -cn --arg p "$path" --arg m "$mode" --arg s "$blob" '{path: $p, mode: $m, type: "blob", sha: $s}'
    fi
  done < <(git -C "$worktree" diff --cached --name-status -z --no-renames HEAD) >"$entries"
  tree="$(jq -s --arg base "$(git -C "$worktree" rev-parse 'HEAD^{tree}')" '{base_tree: $base, tree: .}' "$entries" |
    gh api -X POST "repos/$full/git/trees" --input - --jq .sha)"
  rm -f "$entries"
  staged="$(git -C "$worktree" write-tree)"
  [ "$tree" = "$staged" ] || die "GitHub built tree $tree, but the staged tree is $staged; nothing was sent"
  jq -n --arg m "$message" --arg t "$tree" --arg p "$(git -C "$worktree" rev-parse HEAD)" --arg also "$also" \
    '{message: $m, tree: $t, parents: ([$p, $also] | map(select(. != "")))}' |
    gh api -X POST "repos/$full/git/commits" --input - --jq .sha
}

# Checks, on GitHub as it is now, that issue $2 is an open task for kogut.
# That is either one of kogut's own issues for alerts or for a major, filed by
# the App itself, which the owner agreed kogut may take on unasked; or an issue
# labelled kogut-task whose latest such label the owner added. Prints
# "finding" for a kogut issue, which keeps tracking its finding and closes on
# its own, and "task" for any other.
kogut_task_check() {
  local full="$1" number="$2" issue actor
  issue="$(gh api "repos/$full/issues/$number")"
  [ "$(jq -r '.state' <<<"$issue")" = open ] || die "#$number is not open"
  jq -e '.pull_request == null' <<<"$issue" >/dev/null || die "#$number is a PR, not an issue"
  if jq -e --arg bot "$(kogut_app_bot)" '.user.login == $bot and any(.labels[]; .name == "kogut")
       and ((.body // "") | test("<!-- kogut-finding: (alerts|major:[^ ]+) -->"))' <<<"$issue" >/dev/null; then
    echo finding
    return
  fi
  jq -e 'any(.labels[]; .name == "kogut-task")' <<<"$issue" >/dev/null || die "#$number is not labelled kogut-task"
  actor="$(gh api "repos/$full/issues/$number/events?per_page=100" \
    --jq '[.[] | select(.event == "labeled" and .label.name == "kogut-task")] | sort_by(.created_at) | last | .actor.login')"
  [ "$actor" = "$(kogut_owner)" ] || die "#$number was labelled kogut-task by $actor, not by the owner"
  if jq -e '(.body // "") | contains("<!-- kogut-finding:")' <<<"$issue" >/dev/null; then echo finding; else echo task; fi
}

# Whether a repository takes feature requests at all (policy.feature.repos).
kogut_feature_enabled() {
  jq -e --arg r "$1" 'any(.policy.feature.repos[]?; . == $r)' "$KOGUT_CONFIG" >/dev/null
}

# Where feature request $3 in $2 ($1 is owner/name) stands, on GitHub as it is
# now, as feature.jq decides: the same rule the digest shows. Fails unless it is
# an open issue. An approval is only as good as this answer, so nothing is cached.
kogut_feature_state() {
  local full="$1" repo="$2" number="$3" issue events comments prs enabled=false
  issue="$(gh api "repos/$full/issues/$number")"
  [ "$(jq -r '.state' <<<"$issue")" = open ] || die "#$number is not open"
  jq -e '.pull_request == null' <<<"$issue" >/dev/null || die "#$number is a PR, not an issue"
  events="$(gh api --paginate "repos/$full/issues/$number/events?per_page=100" --jq '.[]' | jq -s .)"
  comments="$(gh api --paginate "repos/$full/issues/$number/comments?per_page=100" \
    --jq '.[] | {author: {login: .user.login}, createdAt: .created_at, body}' | jq -s .)"
  # shellcheck disable=SC2016 # these are jq's variables
  prs="$(gh pr list -R "$full" --state open --author "app/$(kogut_app_slug)" --limit 50 --json number,body |
    jq -c --arg n "$number" '[.[] | select((.body // "") | test("(?i)\\b(closes|fixes|resolves|refs) #\($n)\\b")) | .number]')"
  if kogut_feature_enabled "$repo"; then enabled=true; fi
  # shellcheck disable=SC2016 # these are jq's variables
  jq -n --argjson issue "$issue" --argjson events "$events" --argjson comments "$comments" '{
      labels: $issue.labels,
      labeled: [$events[] | select(.event == "labeled" and .label.name == "kogut-feature") | {actor: .actor.login, at: .created_at}],
      approvals: [$events[] | select(.event == "labeled" and .label.name == "kogut-plan-approved") | {actor: .actor.login, at: .created_at}],
      comments: $comments}' |
    jq -r --arg owner "$(kogut_owner)" --arg app "$(kogut_app_slug)" --argjson enabled "$enabled" --argjson prs "$prs" \
      -f "$KOGUT_ROOT/scripts/feature-state.jq"
}

# A feature stays small enough to review. Counts the staged change in worktree $1,
# plus for a follow-up what PR $2 (gh's JSON with files) already holds, leaving
# out lockfiles, which nobody reads. Dies past policy.feature.max_files or max_lines.
# A refresh passes no PR and the base it merged in as $3: the staged change
# against that base is then all the PR holds.
kogut_feature_size() {
  local worktree="$1" pr="${2:-}" from="${3:-HEAD}" stat lines files max_lines max_files
  [ -n "$pr" ] || pr='{}'
  stat="$(git -C "$worktree" diff --cached --numstat --no-renames "$from")"
  # shellcheck disable=SC2016 # these are jq's variables
  read -r lines files <<<"$(jq -Rrs --argjson pr "$pr" '
    def locked: test("(^|/)(package-lock\\.json|pnpm-lock\\.yaml|yarn\\.lock)$");
    def count: if . == "-" then 0 else tonumber end;
    [split("\n")[] | select(. != "") | split("\t") | {lines: ((.[0] | count) + (.[1] | count)), path: .[2]} | select(.path | locked | not)] as $staged
    | [($pr.files // [])[] | select(.path | locked | not) | {lines: (.additions + .deletions), path}] as $held
    | "\([$staged[].lines, $held[].lines] | add // 0) \([$staged[].path, $held[].path] | unique | length)"' <<<"$stat")"
  max_lines="$(jq -r '.policy.feature.max_lines // 0' "$KOGUT_CONFIG")"
  max_files="$(jq -r '.policy.feature.max_files // 0' "$KOGUT_CONFIG")"
  [ "$lines" -le "$max_lines" ] || die "this feature changes $lines lines, and the limit is $max_lines: split it"
  [ "$files" -le "$max_files" ] || die "this feature changes $files files, and the limit is $max_files: split it"
}

# The fixes in progress in a repository, one slug per line: a worktree exists from
# fix-start.sh until the PR opens or the fix is discarded.
kogut_fix_worktrees() {
  local base="$KOGUT_ROOT/.kogut/fixes/$1"
  [ -d "$base" ] || return 0
  find "$base" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;
}

# Creates a label in a repository unless it is there already. Needs GH_TOKEN
# exported with the App's token.
kogut_ensure_label() {
  local full="$1" name="$2" color="$3" description="$4"
  gh api "repos/$full/labels/$name" >/dev/null 2>&1 ||
    gh api -X POST "repos/$full/labels" -f name="$name" -f color="$color" -f description="$description" >/dev/null
}

# The kogut GitHub App (scripts/app.sh registers it). The id is empty until then.
kogut_app_id() { jq -r '.app.id // empty' "$KOGUT_CONFIG"; }
kogut_app_slug() { jq -r '.app.slug' "$KOGUT_CONFIG"; }
kogut_app_bot() { echo "$(kogut_app_slug)[bot]"; }

# The App's private key lives outside the repository, and a deny rule keeps the
# model from reading it. Only kogut_app_token opens it.
kogut_app_key() { echo "${KOGUT_APP_KEY:-$HOME/.config/kogut/$(kogut_app_slug).private-key.pem}"; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# A JWT that proves to GitHub the caller holds the App's key, valid for nine
# minutes. It is only good for asking GitHub for installation tokens.
kogut_app_jwt() {
  local id key now header claims signature
  id="$(kogut_app_id)"
  [ -n "$id" ] || die "the kogut App is not registered: see ./scripts/app.sh"
  key="$(kogut_app_key)"
  [ -r "$key" ] || die "the App's private key is missing: $key"
  command -v openssl >/dev/null || die "openssl is not installed"
  now="$(date +%s)"
  header="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)"
  claims="$(printf '{"iat":%d,"exp":%d,"iss":%d}' "$((now - 60))" "$((now + 540))" "$id" | b64url)"
  signature="$(printf '%s.%s' "$header" "$claims" | openssl dgst -sha256 -sign "$key" -binary | b64url)"
  echo "$header.$claims.$signature"
}

# An installation token for one watched repository, valid for an hour. Every
# write kogut makes on GitHub uses it, so the write shows as the App's bot and
# cannot bypass a ruleset the way the owner's token can. Assign it to a variable
# and check it before use: in `GH_TOKEN="$(kogut_app_token r)" gh …` a failure
# would leave GH_TOKEN empty, and gh would quietly fall back to the owner.
# An optional second argument narrows the token to some permissions, such as
# '{"actions":"write"}'; GitHub refuses one the installation was not granted.
kogut_app_token() {
  local repo="$1" permissions="${2:-}" jwt installation
  command -v curl >/dev/null || die "curl is not installed"
  jwt="$(kogut_app_jwt)" || exit 1
  installation="$(curl -fsS -H "Authorization: Bearer $jwt" -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$(kogut_owner)/$repo/installation" | jq -er '.id')" ||
    die "the kogut App is not installed on $repo"
  curl -fsS -X POST -H "Authorization: Bearer $jwt" -H 'Accept: application/vnd.github+json' \
    --data "$(jq -cn --arg r "$repo" --arg p "$permissions" \
      '{repositories: [$r]} + (if $p == "" then {} else {permissions: ($p | fromjson)} end)')" \
    "https://api.github.com/app/installations/$installation/access_tokens" | jq -er '.token' ||
    die "GitHub refused an installation token for $repo${permissions:+ with $permissions: has the owner granted it to the App?}"
}

# Whether the owner has yet to install the App on a repository, asked with the
# App's JWT. Prints why and succeeds when GitHub says it is not installed there,
# the way kogut_held does, so a run over every repository can skip one that is
# new to kogut and say so. Fails when it is installed, and when the question
# cannot be asked (no key, no network): then the token request says what is wrong.
kogut_app_missing() {
  local jwt code
  jwt="$(kogut_app_jwt 2>/dev/null)" || return 1
  code="$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $jwt" -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$(kogut_owner)/$1/installation" 2>/dev/null)" || return 1
  [ "$code" = 404 ] || return 1
  echo "the kogut App is not installed on $1"
}

# Whom kogut reads GitHub as, from policy.read_as. "owner", the default, is gh's
# login: it carries the admin bypass, and over SSH it cannot reach the keychain.
# "app" is a read-only installation token of the App, whose key is a file. Writes
# go as the App either way.
kogut_read_as() {
  local as
  as="$(jq -r '.policy.read_as // "owner"' "$KOGUT_CONFIG")"
  case "$as" in
    owner | app) echo "$as" ;;
    *) die "policy.read_as must be \"owner\" or \"app\", not \"$as\"" ;;
  esac
}

# Every permission kogut's reads use, at read level: administration for classic
# branch protection (rulesets need only metadata), secrets for the names and
# dates of Actions secrets, vulnerability_alerts for Dependabot alerts. The
# watched repositories are public, so their check runs and annotations read
# without checks. ./scripts/app.sh check lists the ones the App was not granted.
KOGUT_READ_PERMISSIONS='{"metadata":"read","contents":"read","pull_requests":"read","issues":"read","actions":"read","administration":"read","secrets":"read","vulnerability_alerts":"read"}'

# Of those, the ones an installation was granted ($1, its permissions as GitHub
# lists them), each at read level, never write. A read token asks for these: one
# the installation lacks would make GitHub refuse the whole token, so it is left
# out, and a read that needs it fails on its own and shows as unreadable.
kogut_read_grants() {
  jq -c --argjson want "$KOGUT_READ_PERMISSIONS" '. as $have | $want | with_entries(select($have[.key] != null))' <<<"$1"
}

# An installation token that can only read, for one or more watched
# repositories, valid for an hour. Like kogut_app_token, assign it and check it.
kogut_app_read_token() {
  local jwt installation id permissions repos
  [ $# -gt 0 ] || die "a read token needs a repository"
  command -v curl >/dev/null || die "curl is not installed"
  jwt="$(kogut_app_jwt)" || exit 1
  installation="$(curl -fsS -H "Authorization: Bearer $jwt" -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$(kogut_owner)/$1/installation")" || die "the kogut App is not installed on $1"
  id="$(jq -er '.id' <<<"$installation")" || die "the kogut App is not installed on $1"
  permissions="$(kogut_read_grants "$(jq -c '.permissions // {}' <<<"$installation")")"
  repos="$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(. != ""))')"
  curl -fsS -X POST -H "Authorization: Bearer $jwt" -H 'Accept: application/vnd.github+json' \
    --data "$(jq -cn --argjson r "$repos" --argjson p "$permissions" '{repositories: $r, permissions: $p}')" \
    "https://api.github.com/app/installations/$id/access_tokens" | jq -er '.token' ||
    die "GitHub refused a read token for $*"
}

# Points gh's reads at the identity policy.read_as names, for repositories $@.
# With "owner" it does nothing, and gh reads with the owner's login as it always
# has. With "app" it exports a read token as GH_TOKEN for the rest of the shell,
# and a write still passes its own token. When no read token can be had the
# caller stops: it never falls back to the owner's login, as an empty GH_TOKEN would.
kogut_read_env() {
  local as token
  as="$(kogut_read_as)" || exit 1
  [ "$as" = app ] || return 0
  token="$(kogut_app_read_token "$@")" || exit 1
  [ -n "$token" ] || die "no read token from the kogut App for $*"
  export GH_TOKEN="$token"
}
