# kogut

A maintenance agent for the AKogut portfolio repositories, built on Claude Code. It runs locally and on demand as the `/kogut` skill. There is no server and no schedule. On GitHub it acts as its own GitHub App, `kogut-agent[bot]`, so the history keeps the agent's work apart from the owner's.

Mandate: keep the watched repositories up to date and green (Dependabot PRs, CI health, repository hygiene). kogut does not build features.

kogut runs on the owner's Claude subscription, through whatever account Claude Code is logged in with. Nothing in it may require an API key: no Agent SDK, no `ANTHROPIC_API_KEY`, no cloud runner. Every step stays inside a local Claude Code session.

## Layout

- `.claude/skills/kogut/SKILL.md`: the procedure `/kogut` follows, covering the parts that need judgement.
- `scripts/`: the deterministic half, meaning collection, policy and every action. `signals.jq` holds the rules that need no judgement, and `issues.jq` decides what happens to each kogut issue.
- `kogut.config.json`: watched repositories, their local clones, the policy numbers and the App's id.
- `.claude/settings.json`: what the agent may run without asking, and what it may never run.
- `.env`: one Discord webhook per repository (see `.env.example`). It is gitignored and the model may not read it; only `scripts/notify.sh` does.
- `~/.config/kogut/kogut-agent.private-key.pem`: the App's private key, outside the repository. The model may not read it; only `kogut_app_token` in `scripts/lib.sh` does. `scripts/app.sh` registers the App and checks its installation.
- `.kogut/`: run state, gitignored. `state.json` is the last snapshot, `outbox/` holds reports and issue diagnoses waiting to be sent, `sent/` holds the reports already posted and the text of opened fix PRs, and `fixes/` holds the worktrees of fixes in progress.
- `tests/`: policy tests for `signals.jq` against `tests/fixtures/state.json`, with the clock pinned by `KOGUT_NOW`.
- `.githooks/pre-commit` and `.gitleaks.toml`: secret scanning. The custom rule catches Discord webhook URLs.
- `.github/`: CI (lint, policy tests, secret scan), Dependabot for actions, templates and the social preview with its HTML source.

## Rules for changing kogut

- Policy lives in code, not in the prompt. A rule that code can check (author, checks, age) belongs in `signals.jq` or in the script that acts on it, so a persuasive PR body cannot talk the model past it.
- Every action goes through a script under `scripts/`. The raw commands (`gh pr merge`, `gh pr create`, `git push`) are `ask` rules in `.claude/settings.json`, never `allow`. An action that needs the owner's approval is an `ask` rule, not a sentence in the prompt.
- A script that writes on GitHub uses the App's installation token from `kogut_app_token`, never the owner's `gh` login. Assign it to a variable and check that it is not empty before use: an empty `GH_TOKEN` makes `gh` fall back to the owner.
- Scripts accept repository names only from `kogut.config.json` (`kogut_require_repo` in `scripts/lib.sh`).
- Scripts are bash, `gh` and `jq`, and must work with macOS bash 3.2. Run `shellcheck scripts/*.sh tests/*.sh` after changing them.
- A rule changed or added in `signals.jq` or `issues.jq` gets a check in `tests/run.sh`. Run `./tests/run.sh`.
- `main` takes pull requests only (ruleset `main`: squash, linear history, required checks `Lint`, `Policy tests` and `Secret scan`). All seven portfolio repositories use the same ruleset, and the repository admin can bypass it on pull requests only. `gh pr merge` is an `ask` rule here, so the owner approves every merge, and it never carries `--admin`. Commits are authored by the owner, with no co-author trailer.
- kogut reads with the owner's `gh` login, which carries the admin bypass, and writes as the App, which is on no bypass list. `scripts/merge-dependabot.sh` never passes `--admin` and refuses to merge unless the gate in `signals.jq` says the PR is ready; keep it that way. `gh pr merge` with `--admin` is denied in `.claude/settings.json`.
- Fix PRs are opened by `kogut-agent[bot]` through `scripts/open-fix-pr.sh`, and the owner merges them on GitHub; kogut never merges its own fixes. What kogut writes in the watched repositories is signed as kogut and does not mention the tooling behind it.
- This repository is public. Nothing personal or secret goes into it: webhooks stay in `.env`, and run output stays in `.kogut/`.
- Everything is in English: reports, Discord posts, code, docs and commits.

## Roadmap

1. Done: `/kogut analyze`, a read-only report in the terminal.
2. Done: Discord. `/kogut` posts each repository's report to its own channel.
3. Phase 0: required checks, auto-merge, Dependabot config and alerts in every repository.
4. Done: merging Dependabot PRs through `scripts/merge-dependabot.sh`, with the owner's approval for each merge.
5. Done: fixes in a worktree (`/kogut fix`), opened by `kogut-agent[bot]` after the owner approves, and merged by the owner.
6. Done: issues as kogut's memory. `scripts/issues.sh` keeps one issue per finding (keys from `signals.jq`, policy in `issues.jq`) and closes it once the finding is gone.
7. Done: follow-up. `kogut_prs[]` in `signals.jq` says what each of kogut's PRs needs, and only the owner's reviews count. `scripts/update-fix-pr.sh` pushes a follow-up commit (fast-forward only, up to `policy.followup_limit`) or answers with a comment.
8. Tasks: issues the owner labels `kogut` become PRs. The scope is maintenance plus migrations, unless the owner widens it.
9. Lockfile fixes: `overrides` plus `npm install --package-lock-only --ignore-scripts` in a fix worktree, for transitive alerts (approved by the owner on 2026-10-30).
