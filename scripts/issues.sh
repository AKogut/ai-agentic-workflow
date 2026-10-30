#!/usr/bin/env bash
# Keeps one GitHub issue per finding in each watched repository, written by the
# kogut App. What needs the owner is tracked where the code lives, the issue
# list shows what is left and what kogut closed, and kogut remembers between
# runs what it already reported.
#
#   ./scripts/issues.sh [--dry-run] [repo ...]
#
# The findings and their keys come from signals.jq, and every decision from
# issues.jq, which tests/run.sh checks:
#   - a finding without an issue gets one: at once when it is `auto`, and for
#     the others (majors) only when the model wrote a diagnosis for it;
#   - an issue whose finding remains gets its facts brought up to date, and its
#     diagnosis replaced when the model wrote a new one;
#   - an issue whose finding is gone is closed with a comment that says so.
# Only open issues that the App created itself and labelled `kogut` are ever
# changed. The model's diagnosis for a finding goes in
# .kogut/outbox/issues/<repo>/<slug>.md, as markdown, and is scanned with
# gitleaks before anything is sent. --dry-run prints the plan and stops.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: issues.sh [--dry-run] [repo ...]"
dry_run=false names=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=true ;;
    -*) die "$usage" ;;
    *)
      kogut_require_repo "$arg"
      names="$names $arg"
      ;;
  esac
done
[ -n "$names" ] || names="$(kogut_repos | tr '\n' ' ')"

label=kogut
bot="$(kogut_app_bot)"
today="$(date -u +%Y-%m-%d)"
homepage="$(jq -r '.app.homepage' "$KOGUT_CONFIG")"
inbox="$KOGUT_ROOT/.kogut/outbox/issues"

# The decisions rest on a fresh collection, never on an old snapshot.
state="$(mktemp)"
trap 'rm -f "$state"' EXIT
# shellcheck disable=SC2086 # repository names contain no spaces
digest="$(KOGUT_STATE="$state" "$KOGUT_ROOT/scripts/collect.sh" $names)"

failed=0
for repo in $names; do
  rdigest="$(jq -c --arg r "$repo" '.repos[] | select(.name == $r)' <<<"$digest")"
  if [ -n "$(jq -r '.error // empty' <<<"$rdigest")" ]; then
    echo "$repo: skipped, the collection failed: $(jq -r '.error' <<<"$rdigest")"
    failed=1
    continue
  fi
  full="$(kogut_owner)/$repo"
  # Checked before use: an empty GH_TOKEN would make gh write as the owner.
  token="$(kogut_app_token "$repo")"
  [ -n "$token" ] || die "no token from the kogut App for $repo"

  existing="$(GH_TOKEN="$token" gh api \
    "repos/$full/issues?state=open&labels=$label&creator=$(jq -rn --arg b "$bot" '$b | @uri')&per_page=100" \
    --jq '[.[] | select(.pull_request == null) | {number, title, url: .html_url, body: (.body // ""),
           key: ([(.body // "") | capture("<!-- kogut-finding: (?<k>.+?) -->").k][0])}]')"

  # The model's diagnoses, by slug. A file without a finding is reported and left alone.
  texts="{}"
  scan=""
  if [ -d "$inbox/$repo" ]; then
    for file in "$inbox/$repo"/*.md; do
      [ -f "$file" ] || continue
      slug="$(basename "$file" .md)"
      if jq -e --arg s "$slug" 'any(.findings[]; .slug == $s)' <<<"$rdigest" >/dev/null; then
        texts="$(jq -c --arg s "$slug" --rawfile t "$file" '. + {($s): $t}' <<<"$texts")"
        scan="$scan$(cat "$file")"$'\n'
      else
        echo "$repo: ignored $file: no current finding has the slug '$slug'"
      fi
    done
  fi
  if [ -n "$scan" ]; then
    printf '%s' "$scan" | kogut_scan || die "gitleaks flagged a diagnosis for $repo; nothing was sent"
  fi

  plan="$(jq -c -n -L "$KOGUT_ROOT/scripts" --argjson d "$rdigest" --argjson issues "$existing" \
    --argjson texts "$texts" --arg today "$today" --arg home "$homepage" \
    'include "issues"; plan($d; $issues; $texts; $today; $home)')"

  if [ "$dry_run" = false ] && jq -e 'any(.[]; .action == "open")' <<<"$plan" >/dev/null; then
    GH_TOKEN="$token" gh api "repos/$full/labels/$label" >/dev/null 2>&1 ||
      GH_TOKEN="$token" gh api -X POST "repos/$full/labels" -f name="$label" -f color=5319e7 \
        -f description="Tracked by kogut, the maintenance agent" >/dev/null
  fi

  # Majors wait for the model's word, so the ones it left alone are one line.
  skipped="$(jq -r '[.[] | select(.action == "skip") | .key | sub("^major:"; "")] | join(", ")' <<<"$plan")"
  [ -z "$skipped" ] || echo "$repo: no diagnosis, so no issue for the majors: $skipped"

  while IFS= read -r step; do
    action="$(jq -r '.action' <<<"$step")"
    title="$(jq -r '.title' <<<"$step")"
    number="$(jq -r '.number // empty' <<<"$step")"
    if [ "$dry_run" = true ]; then
      case "$action" in
        keep) echo "$repo: unchanged: #$number $title" ;;
        close) echo "$repo: would close #$number: $title"$'\n'"    $(jq -r '.comment' <<<"$step")" ;;
        open | update)
          echo "$repo: would $action: ${number:+#$number }$title"
          jq -r '.body' <<<"$step" | sed 's/^/    /'
          ;;
      esac
      continue
    fi
    case "$action" in
      open)
        created="$(jq '{title, body, labels: ["'"$label"'"]}' <<<"$step" |
          GH_TOKEN="$token" gh api -X POST "repos/$full/issues" --input - --jq '"#\(.number) \(.html_url)"')"
        echo "$repo: opened $created: $title"
        ;;
      update)
        jq '{title, body}' <<<"$step" |
          GH_TOKEN="$token" gh api -X PATCH "repos/$full/issues/$number" --input - >/dev/null
        echo "$repo: updated #$number: $title"
        ;;
      close)
        jq '{body: .comment}' <<<"$step" |
          GH_TOKEN="$token" gh api -X POST "repos/$full/issues/$number/comments" --input - >/dev/null
        GH_TOKEN="$token" gh api -X PATCH "repos/$full/issues/$number" -f state=closed -f state_reason=completed >/dev/null
        echo "$repo: closed #$number: $title"
        ;;
      keep) echo "$repo: unchanged #$number: $title" ;;
    esac
    # A diagnosis that reached GitHub is filed away, so the next run starts clean.
    if [ "$(jq -r '.text // false' <<<"$step")" = true ]; then
      mkdir -p "$KOGUT_ROOT/.kogut/sent"
      slug="$(jq -r '.slug' <<<"$step")"
      mv "$inbox/$repo/$slug.md" "$KOGUT_ROOT/.kogut/sent/$(date +%Y%m%d-%H%M%S)-issue-$repo-$slug.md"
    fi
  done < <(jq -c '.[]' <<<"$plan")
done
exit "$failed"
