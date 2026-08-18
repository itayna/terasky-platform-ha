# ADR-0001: Application code and platform state live in separate repositories

- **Status**: Accepted
- **Date**: 2026-08-17

## Context

The service is framed as "the first of many". Two things need to be versioned:
the application (source, tests, Dockerfile, its CI) and the desired cluster state
(manifests, policy, environment pins). Argo CD reconciles from whatever
repository holds the second.

The application repository is a fork of a public upstream. The platform
repository holds sealed secrets, cluster topology, and the exact identity the
admission policy trusts.

## Decision

Two repositories:

- `itayna/java-sample-app` (public) — source, Dockerfile, `delivery.yml`.
- `itayna/terasky-platform-ha` (private) — cluster configs, Argo CD
  Applications, Kyverno policy, per-environment manifests, sealed secrets, docs.

CI in the application repository writes exactly one line into the platform
repository — the dev image tag — using an SSH deploy key scoped to that one
repository.

## Consequences

- The deploy input has its own access control. An application developer can
  merge code without holding write access to prod state.
- The audit question "what is running in prod and who put it there" is answered
  by one repository's git log, not by correlating two.
- Cost: a commit reaching prod spans two repositories, so the flow is harder to
  read end to end, and the deploy key is a credential to rotate
  ([RUNBOOK.md](../../RUNBOOK.md#rotating-the-ci-deploy-key)).

## Alternatives rejected

**Monorepo (app + manifests together).** Simpler to follow, and a single PR can
change code and its manifest atomically. Rejected because the platform
repository is the enforcement boundary: with one repository, every application
contributor gets write access to the file that decides what runs in prod, and
the sealed secrets and trusted signing identity sit in a public fork's history.

**Manifests in the app repository, Argo CD pointed at each app repo.** Scales
per-team ownership nicely and is common with Flux. Rejected for now because the
platform-wide pieces — Kyverno policy, cluster bootstrap, environment topology —
have no natural home under any single service, and Stage 2 needs one place where
a platform operator changes something for all services at once.
