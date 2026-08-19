# ADR-0010: Floating major tag for the pipeline, with a pinnable minor

- **Status**: Accepted
- **Date**: 2026-08-19

## Context

With the pipeline centralised ([ADR-0008](0008-reusable-workflow-central-pipeline.md)),
every service names a version of it. That reference decides two things at once: how
a mandatory platform change reaches N services, and how much of a service's build
can change without the owning team doing anything.

Both failure modes are real. Pin too tightly and the platform cannot ship a
security gate without N pull requests — the problem centralisation was meant to
solve. Pin too loosely and an unreviewed change to a shared file breaks or
silently alters every service's build at once.

## Decision

| Ref | Meaning |
|---|---|
| `@v1` | floating major, moves as `v1.x` releases land. What services use. |
| `@v1.0`, `@v1.1` | immutable release. For a service that must opt out temporarily. |
| `@main` | unversioned; the platform's own test surface. Never referenced by a service. |

Shipping a change to every service:

1. Commit it in `platform-workflows`.
2. Tag `v1.1`, then move the floating tag: `git tag -f v1 v1.1 && git push -f origin v1`.
3. Services pick it up on their next push. Nothing changes in any service repository.

Breaking changes get `v2` and a new floating tag; `v1` keeps working, and a service
moves by editing one `uses:` line. `bin/scorecard` reads each service's pinned
version from its `delivery.yml` and reports it in `CATALOG.md`, so "who has not
upgraded" is a table rather than an investigation.

## Rationale

- **The mandatory-step case is the design target.** A new Trivy gate or an SBOM
  attestation has to reach every service without the platform team editing code it
  does not own, and without waiting on the slowest team's review queue.
- **Rollback is moving one tag back**, because `v1.x` tags are immutable. That is
  the cheapest possible recovery from a bad platform release.
- **Opting out stays possible and stays visible.** A team that cannot absorb a
  change this week pins `@v1.0`; the scorecard renders that as `⚠️ v1.0`, so the
  exception is a row in a table rather than a private arrangement.
- **The pin lives in the service's own history.** The one line that decides which
  platform version builds a service is reviewable where its owners work.

## Consequences

- A bad `v1` reaches every service simultaneously. The mitigation is procedural
  (test on `@main` first, then tag) plus tag-move rollback; there is no gradual
  rollout, which is the price of not having N pull requests.
- `git push -f origin v1` is a force-push against a shared ref. It is the
  documented mechanism, not an accident, and the procedure is written down in
  [RUNBOOK.md](../../RUNBOOK.md).
- Services do not pin the actions *inside* the pipeline; those are pinned once, in
  `platform-workflows`, which is where a supply-chain review of them belongs.
- The signature identity contains the resolved tag
  (`...java-service-delivery.yml@refs/tags/v1.0`), so the Kyverno policy and the
  scorecard both match `refs/tags/v*` rather than an exact version. That is
  deliberate: pinning admission to one pipeline version would make every platform
  release a cluster change.

## Alternatives rejected

**SHA-pin the reusable workflow in every service** (`@<40-char sha>`). The
strongest supply-chain position: what a service builds with cannot change without
a reviewed commit in that service. Rejected because it makes the platform's
security bar hostage to N review queues, and because the mitigation for the
recognised risk of floating tags — Dependabot bumping pins per repository — brings
back exactly the N-pull-request workflow, only automated and noisier.

**No versioning; every service references `@main`.** Zero release ceremony, and
the platform team's changes are live immediately. Rejected because there would be
no way to opt out for one release, no immutable ref to roll back to, and any
work-in-progress commit would ship to production builds. Keeping `@main` as the
platform's own test surface preserves the benefit without the exposure.

**A `v1.2.3` patch level with the full semver ladder.** More expressive. Rejected
as ceremony without a consumer: nothing here distinguishes a patch from a minor,
and a two-level scheme (`v1`, `v1.x`) already supports floating, pinning and
rollback.
