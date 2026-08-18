# ADR-0006: Dev promotion is automatic, prod promotion is a manual gate

- **Status**: Accepted
- **Date**: 2026-08-18

## Context

Both environments read from this repository, so "promotion" means: which commit
changes which `kustomization.yaml`, and who is allowed to make it. The
assignment asks for a clear, explained promotion flow between at least two
environments.

## Decision

- **Dev**: the last job of `delivery.yml` rewrites `newTag` in
  `environments/dev/kustomization.yaml` and pushes to `main`. Every green build
  reaches dev with no human involved.
- **Prod**: CI never writes to `environments/prod`. A `workflow_dispatch`
  workflow in this repository (`.github/workflows/promote-prod.yml`) takes a tag
  — defaulting to whatever dev currently runs — re-runs `cosign verify` against
  the pinned OIDC identity, and opens a PR changing the prod tag. Merging the PR
  is the deployment.

## Consequences

- The set of images that ever reached prod is exactly the set of merged
  promotion PRs: one queryable list, with an author and a timestamp.
- Reverting a prod deploy is reverting a PR — the same mechanism as any other
  change, so the rollback path needs no separate tooling.
- The signature is verified a second time, at promotion, by a workflow in a
  different repository from the one that signed. A compromised app-repo pipeline
  cannot both mint and approve its own prod release.
- Cost: prod is only as fresh as the last human action, and the default-to-dev's
  tag behaviour means promoting without thinking is still one click. The gate is
  a speed bump plus an audit record, not an approval process.

## Alternatives rejected

**Auto-promote to prod on green dev.** Fastest lead time, and defensible with
strong automated verification behind it. Rejected because the only signal
available here is an Actuator health check ([ADR-0003](0003-argo-rollouts.md)) —
too weak to be the sole thing standing between a build and production.

**Argo CD Image Updater watching the registry.** Removes the CI-writes-to-Git
step entirely. Rejected because it makes the registry, rather than Git, the
trigger — the deployed state is then decided by a tag that can be moved or
re-pushed, and the "what is running and who put it there" answer stops being a
git log.

**A `staging` branch promoted by merge (branch-per-environment).** Familiar and
gives a natural PR gate. Rejected because merging branches drags along every
unrelated change made since the last promotion; a per-environment directory
promotes exactly one tag line and nothing else, and diverging branches are a
recurring source of "why is prod running something dev never had".
