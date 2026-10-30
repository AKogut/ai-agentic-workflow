# kogut

A maintenance agent for the AKogut portfolio repositories, built on Claude Code. It runs locally and on demand as the `/kogut` skill. There is no server and no schedule.

Mandate: keep the watched repositories up to date and green (Dependabot PRs, CI health, repository hygiene). kogut does not build features.

kogut runs on the owner's Claude subscription, through whatever account Claude Code is logged in with. Nothing in it may require an API key: no Agent SDK, no `ANTHROPIC_API_KEY`, no cloud runner. Every step stays inside a local Claude Code session.

## Layout

- `.claude/skills/kogut/SKILL.md`: the procedure `/kogut` follows, covering the parts that need judgement.
- `scripts/`: the deterministic half, meaning collection, policy and every action. `signals.jq` holds the rules that need no judgement.
- `kogut.config.json`: watched repositories, their local clones and the policy numbers.
- `.claude/settings.json`: what the agent may run without asking, and what it may never run.
- `.env`: one Discord webhook per repository (see `.env.example`). It is gitignored and the model may not read it; only `scripts/notify.sh` does.
- `.kogut/`: run state, gitignored. `state.json` is the last snapshot, `outbox/` holds reports waiting to be posted, and `sent/` holds the reports already posted.
- `tests/`: policy tests for `signals.jq` against `tests/fixtures/state.json`, with the clock pinned by `KOGUT_NOW`.
- `.githooks/pre-commit` and `.gitleaks.toml`: secret scanning. The custom rule catches Discord webhook URLs.
- `.github/`: CI (lint, policy tests, secret scan), Dependabot for actions, templates and the social preview with its HTML source.

## Rules for changing kogut

- Policy lives in code, not in the prompt. A rule that code can check (author, checks, age) belongs in `signals.jq` or in the script that acts on it, so a persuasive PR body cannot talk the model past it.
- Every action goes through a script under `scripts/`. The raw commands (`gh pr merge`, `git push`) are `ask` rules in `.claude/settings.json`, never `allow`. An action that needs the owner's approval is an `ask` rule, not a sentence in the prompt.
- Scripts accept repository names only from `kogut.config.json` (`kogut_require_repo` in `scripts/lib.sh`).
- Scripts are bash, `gh` and `jq`, and must work with macOS bash 3.2. Run `shellcheck scripts/*.sh tests/*.sh` after changing them.
- A rule changed or added in `signals.jq` gets a check in `tests/run.sh`. Run `./tests/run.sh`.
- `main` takes pull requests only (ruleset `main`: squash, linear history, required checks `Lint`, `Policy tests` and `Secret scan`). All seven portfolio repositories use the same ruleset, and the repository admin can bypass it on pull requests only. `gh pr merge` is an `ask` rule here, so the owner approves every merge, and it never carries `--admin`. Commits are authored by the owner, with no co-author trailer.
- kogut runs on the owner's token, and that token carries the admin bypass. The merge script (roadmap step 4) must never pass `--admin`, and must refuse to merge unless the gate in `signals.jq` says the PR is ready.
- This repository is public. Nothing personal or secret goes into it: webhooks stay in `.env`, and run output stays in `.kogut/`.
- Everything is in English: reports, Discord posts, code, docs and commits.

## Roadmap

1. Done: `/kogut analyze`, a read-only report in the terminal.
2. Done: Discord. `/kogut` posts each repository's report to its own channel.
3. Phase 0: required checks, auto-merge, Dependabot config and alerts in every repository.
4. Merging Dependabot PRs through a guarded script.
5. Fixes in a worktree, opened as PRs after the owner approves.
