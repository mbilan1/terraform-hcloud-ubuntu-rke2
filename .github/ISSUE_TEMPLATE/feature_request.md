---
name: Feature request
about: Propose a feature or enhancement for terraform-hcloud-rke2
title: "feat: "
labels: ["enhancement", "needs-triage"]
assignees: []

---

## Problem statement

What operator pain or limitation does this solve?

## Proposed solution

Describe desired behavior and user-facing inputs/outputs.

## Scope

- [ ] Root module wiring
- [ ] `modules/infrastructure`
- [ ] `modules/addons`
- [ ] `examples/*`
- [ ] tests (`tests/*.tftest.hcl`)
- [ ] docs (`README.md`, `docs/ARCHITECTURE.md`)

## Architecture and guardrails impact

<!-- DECISION: We ask for architecture/guardrail impact early because this module
	enforces non-trivial coupling (DNS↔Harmony, dual LBs, addon ordering), and
	feature requests that ignore these constraints often become invalid at review. -->

- Does this affect dual load balancer behavior?
- Does this affect DNS ↔ Harmony coupling?
- Does this add/change `check {}` guardrails in `guardrails.tf`?
- Does this require new inputs in `variables.tf`?

## Alternatives considered

List alternatives and why they are less suitable.

## External dependencies (if any)

If provider/chart/API versions are involved, include live source links used for verification.

- Terraform Registry / provider releases:
- Helm chart / upstream releases:
- Hetzner API/docs:

## Acceptance criteria

- [ ] Behavior is clearly testable
- [ ] Backward compatibility defined
- [ ] Required docs updates identified
- [ ] Security implications assessed
- [ ] FinOps/cost impact noted (if applicable)

## Optional implementation notes

Share rough implementation ideas if you already evaluated the code paths.

## Additional context

Any context, examples, or references.
