## Summary

<!-- What changes, and why. -->

## Type of change

- [ ] feat: kogut does something new
- [ ] fix
- [ ] policy: a rule in `signals.jq` or a guard in `scripts/`
- [ ] permissions: `.claude/settings.json`
- [ ] docs
- [ ] ci / chore

## Checklist

- [ ] `./tests/run.sh` passes, and a changed rule has a test
- [ ] `shellcheck scripts/*.sh tests/*.sh` passes
- [ ] A new action goes through a script, and its raw command is denied or needs approval
- [ ] Nothing secret is committed (the pre-commit hook and CI scan with gitleaks)
