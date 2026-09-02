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
- `itayna/terasky-platform-ha` — cluster configs, Argo CD Applications,
  Kyverno policy, per-environment manifests, sealed secrets, docs. Designed
  as a private repository; public at the time of review so it can be read
  without collaborator invitations (see *Visibility* below).

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

## Visibility

The split is an enforcement boundary on **write** access, and that survives
the platform repository being public. Nothing in it depends on secrecy: the
`SealedSecret`s are safe to publish by construction — they decrypt only on the
cluster whose controller key sealed them ([ADR-0004](0004-sealed-secrets.md));
the Argo CD deploy key and the pipeline's write key are held in cluster and in
service-repository secrets, never here; and the trusted signing identity is
verified at admission, so knowing it buys an attacker nothing. What a public
repository does give up is that cluster topology and environment pins are
readable by anyone, which in a real organisation is reason enough to keep it
private. The rejection of the monorepo below stands either way: it is about who
can *change* the prod tag, not who can see it.

## Alternatives rejected

**Monorepo (app + manifests together).** Simpler to follow, and a single PR can
change code and its manifest atomically. Rejected because the platform
repository is the enforcement boundary: with one repository, every application
contributor gets write access to the file that decides what runs in prod, and
the prod tag sits in a fork's history that every application contributor can
push to.

**Manifests in the app repository, Argo CD pointed at each app repo.** Scales
per-team ownership nicely and is common with Flux. Rejected for now because the
platform-wide pieces — Kyverno policy, cluster bootstrap, environment topology —
have no natural home under any single service, and Stage 2 needs one place where
a platform operator changes something for all services at once.
