# Security policy

## Reporting a vulnerability

Please do not open a public issue. Report it privately through [GitHub's vulnerability reporting](https://github.com/AKogut/ai-agentic-workflow/security/advisories/new). I will acknowledge it within a few days.

Reports that matter most here are ways to make kogut act beyond its policy: prompt injection through PR bodies, release notes or CI logs that leads to a merge, a write or a leaked secret.

## How the project protects itself

| Risk | Control |
|---|---|
| Instructions hidden in Dependabot PR bodies, release notes or CI logs | Treated as data by the skill. The model may run only allow-listed, read-only commands. Merges, fix PRs, issue changes, pushes and repository edits are denied or require the owner's approval in [`.claude/settings.json`](.claude/settings.json). |
| The model talked past the merge policy | The policy is code ([`scripts/signals.jq`](scripts/signals.jq)), covered by [tests](tests/run.sh). The model can hold a PR back, but it cannot merge past a blocker. |
| Leaked Discord webhooks | URLs are kept only in a gitignored `.env`, which the model is denied from reading. [`notify.sh`](scripts/notify.sh) reads them, accepts only Discord webhook URLs and never prints them. |
| Mass pings through quoted text | Every Discord message is sent with mentions disabled. |
| Secrets committed by mistake | A [pre-commit hook](.githooks/pre-commit) and a CI job scan with gitleaks, including a rule for Discord webhooks. GitHub secret scanning and push protection are enabled. |
| A malicious package in a Dependabot update | Dependabot branches are never installed or run locally, only in GitHub's CI. A 3-day cooldown applies before an update counts as ready. |
| Unreviewed changes to `main` | A ruleset allows changes only through pull requests that pass the required checks: squash merges, linear history, no force pushes, no deletion. Only the owner can override a red check, and only on a pull request. |
| kogut merging past a red check | kogut writes on GitHub as its own GitHub App, `kogut-agent`, which is on no ruleset's bypass list, so the owner's override is not available to it. [`merge-dependabot.sh`](scripts/merge-dependabot.sh) and [`open-fix-pr.sh`](scripts/open-fix-pr.sh) refuse to run without the App's token rather than fall back to the owner's login. The merge script never passes `--admin` and merges only what the gate in `signals.jq` calls ready. Raw `gh pr merge` needs the owner's approval on every run, and with `--admin` it is denied. |
| A leaked App private key | The key lives in `~/.config/kogut/` (directory mode 700, file mode 600), outside the repository, and the model is denied from reading it. Only `kogut_app_token` in [`lib.sh`](scripts/lib.sh) opens it. Each token it mints covers one repository and expires after an hour. The App can write code, PRs, issues and workflow files in the watched repositories, and nothing else. A leaked key is revoked in the App's settings. |
| kogut flooding or closing issues on a hostile prompt | [`issues.sh`](scripts/issues.sh) opens issues only for findings that `signals.jq` produces, and opens one for a major only when the model writes a diagnosis. It changes or closes only open issues that the App itself filed with the `kogut` label, and it closes one only when the finding is gone from a fresh collection, never on the model's say-so. The policy is in [`issues.jq`](scripts/issues.jq) and is tested. Diagnoses are scanned with gitleaks, and the owner approves each run. |
| A fix PR that leaks a secret or plants a hostile workflow | Nothing leaves the machine before [`open-fix-pr.sh`](scripts/open-fix-pr.sh) scans the changed lines and the PR text with gitleaks. A change under `.github/workflows/` needs `--workflows`, which the owner sees in the approval prompt, because a workflow on the PR branch runs with the repository's secrets before review. The owner sees the diff (`--dry-run`) before approving, and only the owner merges a fix. Titles are limited to maintenance types (`fix`, `ci`, `build`, `chore`, `docs`, `test`). |

## Supported versions

Only `main` is maintained.
