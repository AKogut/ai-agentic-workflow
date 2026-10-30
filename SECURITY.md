# Security policy

## Reporting a vulnerability

Please do not open a public issue. Report it privately through [GitHub's vulnerability reporting](https://github.com/AKogut/ai-agentic-workflow/security/advisories/new). I will acknowledge it within a few days.

Reports that matter most here are ways to make kohut act beyond its policy: prompt injection through PR bodies, release notes or CI logs that leads to a merge, a write or a leaked secret.

## How the project protects itself

| Risk | Control |
|---|---|
| Instructions hidden in Dependabot PR bodies, release notes or CI logs | Treated as data by the skill. The model may run only allow-listed, read-only commands. Merges, pushes and repository edits are denied or require the owner's approval in [`.claude/settings.json`](.claude/settings.json). |
| The model talked past the merge policy | The policy is code ([`scripts/signals.jq`](scripts/signals.jq)), covered by [tests](tests/run.sh). The model can hold a PR back, but it cannot merge past a blocker. |
| Leaked Discord webhooks | URLs are kept only in a gitignored `.env`, which the model is denied from reading. [`notify.sh`](scripts/notify.sh) reads them, accepts only Discord webhook URLs and never prints them. |
| Mass pings through quoted text | Every Discord message is sent with mentions disabled. |
| Secrets committed by mistake | A [pre-commit hook](.githooks/pre-commit) and a CI job scan with gitleaks, including a rule for Discord webhooks. GitHub secret scanning and push protection are enabled. |
| A malicious package in a Dependabot update | Dependabot branches are never installed or run locally, only in GitHub's CI. A 3-day cooldown applies before an update counts as ready. |
| Unreviewed changes to `main` | A ruleset allows changes only through pull requests that pass the required checks: squash merges, linear history, no force pushes, no deletion. Only the owner can override a red check, and only on a pull request. |
| kohut merging past a red check with the owner's token | The owner's override travels with the token kohut runs on. Raw `gh pr merge` stays denied, and merges will go only through a script that never passes `--admin`. |

## Supported versions

Only `main` is maintained.
