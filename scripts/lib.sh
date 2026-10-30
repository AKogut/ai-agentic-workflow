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

# Local clone of a configured repository, with ~ expanded.
kogut_repo_path() {
  local p
  p="$(jq -r --arg r "$1" '.repos[] | select(.name == $r) | .path' "$KOGUT_CONFIG")"
  echo "${p/#\~/$HOME}"
}

# Default branch of a configured repository: the local clone's origin/HEAD, or
# GitHub's answer when the clone does not record it.
kogut_default_branch() {
  local dir branch
  dir="$(kogut_repo_path "$1")"
  branch="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  branch="${branch#origin/}"
  if [ -z "$branch" ]; then
    branch="$(gh repo view "$(kogut_owner)/$1" --json defaultBranchRef --jq .defaultBranchRef.name)"
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
# message. kogut maintains and does not build features, so the title must use
# one of the maintenance types of Conventional Commits. The rest of the file,
# after a blank second line, is the PR body or the follow-up's comment.
kogut_fix_title() {
  local text="$1" title title_re='^(fix|ci|build|chore|docs|test)(\([a-z0-9._/-]+\))?: .+$'
  [ -s "$text" ] || die "the text is missing: $text"
  title="$(head -n 1 "$text")"
  [[ "$title" =~ $title_re ]] || die "the title must be a maintenance Conventional Commit (fix, ci, build, chore, docs, test): $title"
  [ "${#title}" -le 72 ] || die "the title is longer than 72 characters"
  [ -z "$(sed -n 2p "$text")" ] || die "the second line of $text must be blank"
  [ -n "$(tail -n +3 "$text" | tr -d '[:space:]')" ] || die "the body of $text is empty"
  echo "$title"
}

# Stages everything in a fix's worktree and checks it. The change must not be
# empty, and it may touch .github/workflows/ only when $2 is true: a workflow
# on a branch runs with the repository's secrets before review, so the owner
# should see that flag in the prompt. Then the changed lines and the text ($3)
# are scanned with gitleaks.
kogut_stage() {
  local worktree="$1" workflows="$2" text="$3" changed
  git -C "$worktree" add -A
  changed="$(git -C "$worktree" diff --cached --name-only --no-renames HEAD)"
  [ -n "$changed" ] || die "the fix changes nothing"
  if grep -q '^\.github/workflows/' <<<"$changed"; then
    [ "$workflows" = true ] || die "the fix changes .github/workflows/: pass --workflows"
  else
    [ "$workflows" = false ] || die "the fix changes no workflow: drop --workflows"
  fi
  { git -C "$worktree" diff --cached --unified=0 HEAD; cat "$text"; } | kogut_scan ||
    die "gitleaks flagged the fix; nothing was sent"
}

# The staged change, for the owner to read before approving.
kogut_show_diff() {
  git -C "$1" diff --cached --stat HEAD
  echo "--- diff"
  git -C "$1" diff --cached HEAD | awk 'NR <= 400 { print } END { if (NR > 400) print "... " NR - 400 " more lines" }'
}

# Builds a worktree's staged change as a commit on GitHub, on top of the
# worktree's HEAD, and prints the commit's id. The blobs and modes are the
# ones git staged, and GitHub's tree must hash to the staged tree, so the
# commit holds exactly the diff that was shown. Needs GH_TOKEN exported with
# the App's token; no git credentials are involved.
kogut_api_commit() {
  local full="$1" worktree="$2" message="$3" entries status path mode sha blob tree staged
  entries="$(mktemp)"
  while IFS= read -r -d '' status && IFS= read -r -d '' path; do
    case "$path" in -* | *$'\n'* | *$'\t'*) die "refusing an unusual path: $path" ;; esac
    if [ "$status" = D ]; then
      read -r mode _ <<<"$(git -C "$worktree" ls-tree HEAD -- "$path")"
      jq -cn --arg p "$path" --arg m "$mode" '{path: $p, mode: $m, type: "blob", sha: null}'
    else
      read -r mode sha _ <<<"$(git -C "$worktree" ls-files -s -- "$path")"
      [ "$mode" != 160000 ] || die "refusing a submodule change: $path"
      blob="$(git -C "$worktree" cat-file blob "$sha" | base64 | tr -d '\n' |
        jq -Rs '{content: ., encoding: "base64"}' |
        gh api -X POST "repos/$full/git/blobs" --input - --jq .sha)"
      [ "$blob" = "$sha" ] || die "GitHub stored $path as $blob, not $sha"
      jq -cn --arg p "$path" --arg m "$mode" --arg s "$blob" '{path: $p, mode: $m, type: "blob", sha: $s}'
    fi
  done < <(git -C "$worktree" diff --cached --name-status -z --no-renames HEAD) >"$entries"
  tree="$(jq -s --arg base "$(git -C "$worktree" rev-parse 'HEAD^{tree}')" '{base_tree: $base, tree: .}' "$entries" |
    gh api -X POST "repos/$full/git/trees" --input - --jq .sha)"
  rm -f "$entries"
  staged="$(git -C "$worktree" write-tree)"
  [ "$tree" = "$staged" ] || die "GitHub built tree $tree, but the staged tree is $staged; nothing was sent"
  jq -n --arg m "$message" --arg t "$tree" --arg p "$(git -C "$worktree" rev-parse HEAD)" \
    '{message: $m, tree: $t, parents: [$p]}' |
    gh api -X POST "repos/$full/git/commits" --input - --jq .sha
}

# Checks, on GitHub as it is now, that issue $2 is an open task the owner
# handed kogut: labelled kogut-task, and the latest such label added by the
# owner. Prints "finding" for an issue kogut files for a finding, which keeps
# tracking it and closes on its own, and "task" for any other.
kogut_task_check() {
  local full="$1" number="$2" issue actor
  issue="$(gh api "repos/$full/issues/$number")"
  [ "$(jq -r '.state' <<<"$issue")" = open ] || die "#$number is not open"
  jq -e '.pull_request == null' <<<"$issue" >/dev/null || die "#$number is a PR, not an issue"
  jq -e 'any(.labels[]; .name == "kogut-task")' <<<"$issue" >/dev/null || die "#$number is not labelled kogut-task"
  actor="$(gh api "repos/$full/issues/$number/events?per_page=100" \
    --jq '[.[] | select(.event == "labeled" and .label.name == "kogut-task")] | sort_by(.created_at) | last | .actor.login')"
  [ "$actor" = "$(kogut_owner)" ] || die "#$number was labelled kogut-task by $actor, not by the owner"
  if jq -e '(.body // "") | contains("<!-- kogut-finding:")' <<<"$issue" >/dev/null; then echo finding; else echo task; fi
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
kogut_app_token() {
  local repo="$1" jwt installation
  command -v curl >/dev/null || die "curl is not installed"
  jwt="$(kogut_app_jwt)" || exit 1
  installation="$(curl -fsS -H "Authorization: Bearer $jwt" -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$(kogut_owner)/$repo/installation" | jq -er '.id')" ||
    die "the kogut App is not installed on $repo"
  curl -fsS -X POST -H "Authorization: Bearer $jwt" -H 'Accept: application/vnd.github+json' \
    --data "$(jq -cn --arg r "$repo" '{repositories: [$r]}')" \
    "https://api.github.com/app/installations/$installation/access_tokens" | jq -er '.token' ||
    die "GitHub refused an installation token for $repo"
}
