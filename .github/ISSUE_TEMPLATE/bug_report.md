---
name: Bug report
about: Report a reproducible bug in terraform-hcloud-rke2
title: "bug: "
labels: ["bug", "needs-triage"]
assignees: []

---

## Bug summary

Describe what failed and where (plan/apply/tests/runtime).

## Reproduction steps

Provide exact steps with minimal configuration.

1.
2.
3.
4.

## Expected behavior

What should happen instead?

## Actual behavior

What happened in practice? Include the first failing error line.

## Environment

<!-- DECISION: We request IaC-specific runtime details (not browser/device metadata)
	because this module's failures are typically provider/version/topology dependent,
	and reproducibility depends on infra context. -->

- Host OS (operator machine):
- OpenTofu version (`tofu version`):
- Module ref (commit/tag):
- Example used (`examples/minimal`, `examples/openedx-tutor`, custom):
- Hetzner locations (`node_locations`):
- Control plane / worker counts:
- `harmony_enabled`:
- `create_dns_record`:
- `cluster_configuration.etcd_backup.enabled`:

## Logs and diagnostics

Paste relevant snippets (redact secrets):

- `tofu validate`
- `tofu test`
- cloud-init (`/var/log/cloud-init-output.log`) excerpt
- RKE2 service logs (`journalctl -u rke2-server -n 100`) excerpt
- `kubectl get nodes -o wide`

## Guardrails and expected checks

If this fails due to a guardrail, include the guardrail error text from `guardrails.tf`.

## Impact

- [ ] Blocks new cluster bootstrap
- [ ] Blocks upgrades/maintenance
- [ ] Affects only optional addons
- [ ] Documentation inconsistency only

## Definition of done (for maintainers)

- [ ] Reproducible locally or in CI
- [ ] Root cause identified
- [ ] Fix keeps module architecture constraints intact (`docs/ARCHITECTURE.md`)
- [ ] `tofu fmt -check`, `tofu validate`, `tofu test` pass
- [ ] Tests added/updated when behavior changes

## Additional context

Anything else that can help with triage.
