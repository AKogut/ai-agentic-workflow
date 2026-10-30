# ai-agentic-workflow

**kohut** is a maintenance agent for my portfolio repositories, built on [Claude Code](https://docs.claude.com/en/docs/claude-code/overview). It reads Dependabot PRs, CI on the default branch and repository settings, and reports for each repository what needs attention and why.

It runs on my machine when I ask it to:

```
/kohut                          # every watched repository, reports posted to Discord
/kohut flakemetry               # just one
/kohut analyze                  # the report in the terminal only, nothing posted
```

Each repository has its own Discord channel. A repository gets a report even when nothing needs doing, so a quiet channel means kohut did not run.

## How it works

Code does whatever needs no judgement, and the model is used only where judgement is needed.

1. `scripts/collect.sh` gathers the state of every repository with `gh`: open PRs and their checks, the run history of each workflow on the default branch, required checks, Dependabot alerts and settings.
2. `scripts/signals.jq` applies the rules that need no judgement and reduces that state to signals. These are the merge blockers (red or missing required checks, conflicts, a 3-day cooldown), failure streaks, flaky workflows, disabled workflows and hygiene gaps.
3. The model works only on what needs judgement. For a major bump it reads the release notes and checks whether the code uses what changed. For a red workflow it reads the failed log (`scripts/failed-log.sh`) and the code (`scripts/repo.sh`), classifies the cause and proposes the smallest fix.

Dependabot PR bodies carry upstream release notes verbatim, and CI logs can contain anything, so neither is trusted. In this version every command the model may run is read-only (`.claude/settings.json`). Later actions will go through scripts that re-check the policy themselves, so persuasive text cannot talk the model into an action the policy does not allow.

## Setup

Requires Claude Code, an authenticated `gh`, `jq` and `curl`. Kohut runs inside Claude Code on its login (a Claude subscription in my case) and needs no API key. Repositories are listed in `kohut.config.json` together with the paths of their local clones. The Discord webhooks go in `.env` (copy `.env.example`), and `./scripts/notify.sh --check` checks them without posting anything.

To run it from anywhere:

```sh
kohut() { (cd ~/GitHubPersonal/ai-agentic-workflow && claude "/kohut $*"); }
```

## Status

Analysis and Discord reports work. Merging Dependabot PRs and fixes opened as PRs after approval come next. The roadmap is in [CLAUDE.md](CLAUDE.md).
