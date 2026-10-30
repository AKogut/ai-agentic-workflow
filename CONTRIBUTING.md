# Contributing

kohut is a personal tool that maintains my own repositories, but issues and ideas are welcome. If you are building something similar, feel free to borrow from it under the MIT license.

## Development setup

```sh
git config core.hooksPath .githooks   # scan staged changes for secrets (needs gitleaks)
./tests/run.sh                        # the policy in scripts/signals.jq
shellcheck scripts/*.sh tests/*.sh
```

## Ground rules

These are the rules from [CLAUDE.md](CLAUDE.md) that a change is reviewed against:

- **Policy lives in code, not in the prompt.** A rule that code can check (author, checks, age) goes in `signals.jq` or the script that acts on it, and gets a test in `tests/run.sh`.
- **Every action goes through a script.** The raw commands (`gh pr merge`, `git push`) are `ask` rules in `.claude/settings.json`, never `allow`. An action that needs approval is an `ask` rule, not a sentence in the prompt.
- **Scripts accept only the repositories in `kohut.config.json`.**
- **Bash 3.2 compatible**, because that is the bash macOS ships.

`main` accepts only pull requests that pass CI. Use [Conventional Commits](https://www.conventionalcommits.org/) for PR titles: the PR is squash-merged and its title becomes the commit message.
