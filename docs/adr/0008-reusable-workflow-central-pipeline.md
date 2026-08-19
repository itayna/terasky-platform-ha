# ADR-0008: One reusable workflow in a platform-owned repository

- **Status**: Accepted
- **Date**: 2026-08-19

## Context

Stage 1 gave `java-sample-app` its own `.github/workflows/delivery.yml`: build,
test, Trivy filesystem and image gates, SPDX SBOM, keyless cosign signature, then
a commit of the new tag into this repository. It works, and it is a copy.

The Stage 2 question is what happens at service #2 and service #20. Concretely:
the platform team decides every image must also carry a signed SBOM attestation.
With per-repository copies that is N pull requests against N repositories owned by
N teams, and the platform's security posture becomes whatever the slowest team
merges. The bar has to be shippable by the people who own it.

## Decision

The pipeline lives in **`itayna/platform-workflows`**, a separate public
repository, as a `workflow_call` reusable workflow
(`.github/workflows/java-service-delivery.yml`). A service's entire delivery
configuration is three lines of `uses:` plus its service name.

Versioning is a floating major tag: services reference `@v1`, the platform moves
`v1` as `v1.x` releases land, and a service that must temporarily opt out pins
`@v1.0` ([ADR-0010](0010-pipeline-version-tags.md)).

## Rationale

- **Adding a mandatory step is one commit plus a tag move.** Every service on
  `@v1` picks it up on its next push, with no change in any service repository
  and no platform-team edit inside code someone else owns.
- **Public, deliberately.** A private reusable workflow can only be called by
  repositories permitted through org Actions settings — an org-admin action per
  service, which is exactly the platform-team bottleneck this removes. The
  workflow contains no secrets; the caller passes them in.
- **The service repository keeps a reviewable pin.** Moving to `v2` is a one-line
  diff in the service's own history, so an upgrade is visible where the team
  looks, not silent.

## Consequences

- **The signing identity changes, and this is the significant one.** With
  `workflow_call` the Fulcio certificate identity is the *called* workflow's ref,
  not the caller's: `.../platform-workflows/.github/workflows/java-service-delivery.yml@refs/tags/v1.0`.
  What a signature proves is therefore "built by version v1.x of the platform
  pipeline", not "built by this service's own workflow". The service repository
  is still recorded in the certificate extensions and in the SBOM.
- That is a real trade — a narrower per-service claim becomes a platform-wide one
  — and it is what makes onboarding need zero platform action: the Kyverno policy
  in `clusters/policies/verify-image-signatures.yaml` trusts **one** identity for
  all services instead of gaining a rule per service. A per-service identity would
  mean editing an admission policy, in a cluster, for every onboarding.
- The policy carries a second attestor entry (`count: 1`, so alternatives) for
  images signed by a service's own pre-v1 workflow, because a rollback to one of
  those images must still admit. It is a migration remnant and is deleted once no
  pre-v1 image is a rollback candidate.
- A bad `v1` reaches every service at once. Mitigated by `v1.x` being immutable,
  so rollback is moving one tag back, and by services being able to pin.
- One more repository to own, with its own release discipline.

## Alternatives rejected

**Template repository with a copied workflow.** Simplest to start: the scaffold
copies a known-good pipeline and every service's CI is self-contained and
independently debuggable. Rejected because copies drift the moment they exist —
the mandatory-step scenario above degrades into chasing N repositories, and the
compliance scorecard would be reduced to reporting how far each copy has drifted
rather than which version it pins.

**Organisation-level required workflows.** GitHub can force a workflow onto every
repository in an org, which is a stronger guarantee than a `uses:` line a team can
edit. Rejected as unavailable here (this is a personal account, not an org) and
because it removes the per-service pin: a service could not opt out of a change
for one release even when the platform team agrees it should, and rollout to all
repositories is all-or-nothing with no canary.

**A composite action.** Reusable at the step level and callable from a matrix.
Rejected because a composite action cannot define jobs, so each caller still
authors the job graph — permissions, `concurrency`, the fan-out between build,
scan, sign and promote — which is precisely the part that must not vary per
service.

**Keeping the copy and enforcing at admission only.** Kyverno already blocks
unsigned images, so an argument exists that CI content need not be centralised.
Rejected because admission cannot see what did not happen: it cannot tell that a
service skipped its Trivy gate or never generated an SBOM, only that the image is
signed by something trusted.
