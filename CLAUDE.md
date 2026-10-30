# kohut

A maintenance agent for the AKogut portfolio repositories, built on Claude Code. It runs locally and on demand as the `/kohut` skill. There is no server and no schedule.

Mandate: keep the watched repositories up to date and green (Dependabot PRs, CI health, repository hygiene). Kohut does not build features.

Kohut runs on the owner's Claude subscription, through whatever account Claude Code is logged in with. Nothing in it may require an API key: no Agent SDK, no `ANTHROPIC_API_KEY`, no cloud runner. Every step stays inside a local Claude Code session.

## Layout

- `.claude/skills/kohut/SKILL.md`: the procedure `/kohut` follows, covering the parts that need judgement.
- `scripts/`: the deterministic half, meaning collection, policy and every action. `signals.jq` holds the rules that need no judgement.
- `kohut.config.json`: watched repositories, their local clones and the policy numbers.
- `.claude/settings.json`: what the agent may run without asking, and what it may never run.
- `.env`: one Discord webhook per repository (see `.env.example`). It is gitignored and the model may not read it; only `scripts/notify.sh` does.
- `.kohut/`: run state, gitignored. `state.json` is the last snapshot, `outbox/` holds reports waiting to be posted, and `sent/` holds the reports already posted.
- `tests/`: policy tests for `signals.jq` against `tests/fixtures/state.json`, with the clock pinned by `KOHUT_NOW`.
- `.githooks/pre-commit` and `.gitleaks.toml`: secret scanning. The custom rule catches Discord webhook URLs.
- `.github/`: CI (lint, policy tests, secret scan), Dependabot for actions, templates and the social preview with its HTML source.

## Rules for changing kohut

- Policy lives in code, not in the prompt. A rule that code can check (author, checks, age) belongs in `signals.jq` or in the script that acts on it, so a persuasive PR body cannot talk the model past it.
- Every action goes through a script under `scripts/`. The raw commands (`gh pr merge`, `git push`) stay denied in `.claude/settings.json`. An action that needs the owner's approval is an `ask` rule, not a sentence in the prompt.
- Scripts accept repository names only from `kohut.config.json` (`kohut_require_repo` in `scripts/lib.sh`).
- Scripts are bash, `gh` and `jq`, and must work with macOS bash 3.2. Run `shellcheck scripts/*.sh tests/*.sh` after changing them.
- A rule changed or added in `signals.jq` gets a check in `tests/run.sh`. Run `./tests/run.sh`.
- `main` takes pull requests only (ruleset `main`: squash, linear history, required checks `Lint`, `Policy tests` and `Secret scan`). `gh pr merge` stays denied here as a kohut guard, so the owner merges. Commits are authored by the owner, with no co-author trailer.
- This repository is public. Nothing personal or secret goes into it: webhooks stay in `.env`, and run output stays in `.kohut/`.
- Reports are in Ukrainian. Code, docs and commits are in English.

## Roadmap

1. Done: `/kohut analyze`, a read-only report in the terminal.
2. Done: Discord. `/kohut` posts each repository's report to its own channel.
3. Phase 0: required checks, auto-merge, Dependabot config and alerts in every repository.
4. Merging Dependabot PRs through a guarded script.
5. Fixes in a worktree, opened as PRs after the owner approves.
