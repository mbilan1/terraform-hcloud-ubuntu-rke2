## Description

<!-- What does this PR do? Why is it needed? -->

## Type of Change

- [ ] `feat` — New feature or capability
- [ ] `fix` — Bug fix
- [ ] `refactor` — Code restructuring (no behavior change)
- [ ] `docs` — Documentation only
- [ ] `chore` — Maintenance (CI, dependencies, tooling)
- [ ] `test` — Adding or updating tests

## Checklist

### Before requesting review:

- [ ] `tofu fmt -check -recursive` passes
- [ ] `tofu validate` passes
- [ ] `tofu test` passes (57 tests, ~3s, $0)
- [ ] No secrets or credentials in the diff
- [ ] Existing code comments preserved (or updated, not deleted)

### If changing variables, guardrails, or conditional logic:

- [ ] `tofu test -filter=tests/variables.tftest.hcl` passes
- [ ] `tofu test -filter=tests/guardrails.tftest.hcl` passes
- [ ] `tofu test -filter=tests/conditional_logic.tftest.hcl` passes

### If changing infrastructure resources:

- [ ] Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before editing
- [ ] New resources have comments explaining WHY (not what)
- [ ] `CHANGELOG.md` updated under `[Unreleased]`

### If changing examples/:

- [ ] Example still matches the current module interface
- [ ] Example README is accurate

### If changing charts/:

- [ ] Helmfile values are valid YAML
- [ ] Changes documented in `charts/README.md`
