# ADR-0012: Golden-path templates are versioned by directory, and migration is explicit

- **Status**: Accepted
- **Date**: 2026-09-02

## Context

Two things reach a service from the platform, and they propagate differently.

The **pipeline** is referenced, not copied: a service names
`java-service-delivery.yml@v1` and the platform moves that tag, so a new
mandatory step reaches every service on its next push with no edit in any
service repository ([ADR-0008](0008-reusable-workflow-central-pipeline.md),
[ADR-0010](0010-pipeline-version-tags.md)).

The **templates** in `templates/service-v1/` are copied. `platformctl` renders
them once, into `environments/{dev,prod}/<service>/`,
`gitops/argocd-apps/<env>/<service>.yaml`, and the service repository's
`delivery.yml` and `CODEOWNERS`. From that moment the rendered files are the
service's own, and nothing propagates. A change to the golden path — different
canary steps, a `namespace` field per service, a NetworkPolicy, changed probe
paths — improves what service #4 gets and leaves services #1–#3 exactly as they
were.

This is the assignment's question: what happens to the ten services scaffolded
from v1 when v2 ships.

## Decision

Templates are versioned by directory. `templates/service-v1/` is frozen once
services exist that were rendered from it; a breaking change to the golden path
becomes `templates/service-v2/`, and `platformctl new` renders the newest.

**Existing services are not migrated automatically.** Migration is a pull
request per service against this repository, authored by the platform team,
reviewed by the service's owner. There is no reconciliation loop that rewrites a
service's manifests underneath it.

Which version a service was rendered from is not tracked today. It is derivable
— the rendered files either match a template or they do not — and the honest
statement is that at three services this has not been worth a column in
`CATALOG.md`.

## Rationale

- **The two mechanisms differ because the artefacts differ.** The pipeline is
  behaviour the platform owns and must be able to change unilaterally; that is
  what a floating tag buys, and it is why the security bar is centralised. The
  manifests are the service's desired state, and a platform team that can
  silently rewrite replica counts, resource limits and probes in another team's
  production deployment has taken ownership it should not have. A copy is the
  right shape here.
- **The blast radius is already bounded where it matters.** Everything a
  compliance failure would come from — signature verification, Trivy gates, SBOM,
  the canary abort criteria — lives in the pipeline or in
  `environments/<env>/_platform/`, not in the per-service render. The
  `ClusterAnalysisTemplate` was moved there deliberately for exactly this reason.
  What a stale template render costs is consistency, not the platform bar.
- **Migration as a reviewed pull request matches how every other change here
  reaches a cluster.** It needs no new mechanism, and it is visible in the same
  history as the promotions.

## Consequences

- Services drift from the current golden path, silently, and the platform has no
  report of it. At three services that is tractable by reading; it will not stay
  that way.
- A `v2` that only adds something (a label, an annotation) is a mechanical
  re-render. One that changes a field a team has since tuned is a merge, and the
  team has to be in the loop — which is the intended cost.
- `platformctl` has no `upgrade` verb. Re-onboarding a live service is refused
  by design, so today a migration is edited by hand from the template.

## What would change this

Two triggers, either one sufficient:

1. **A template change the platform must be able to force**, the way it can
   force a pipeline step. If that ever becomes true, the right answer is not a
   better template — it is moving that thing out of the per-service render into
   `_platform/` or into the pipeline, where the platform already owns it.
2. **Enough services that drift stops being readable.** Then: stamp the template
   version as an annotation on the generated `Application` at render time, add a
   Template column to `bin/scorecard` derived from it, and give `platformctl` an
   `upgrade <service>` that re-renders and opens the pull request. That is a
   small amount of work and it is deliberately not done yet — a version stamp
   with three services and no migration to perform is ceremony.

## Alternatives rejected

**Render the templates through a reference, not a copy** — a shared kustomize
base in this repository that each service overlays. Genuinely propagating: a
base change reaches every service on the next sync. Rejected because it makes
every service's production manifests change when the platform team commits, with
no review by the owning team and no per-service opt-out — the same objection
that makes the pipeline's floating tag *right* for CI and wrong for desired
state. It also turns a readable per-service directory into an overlay that has
to be `kustomize build`-ed to know what is deployed, which costs exactly the
"read the repository and see what runs" property the split buys.

**A Crossplane composition as the service API**, continuously reconciling the
rendered state. Solves drift properly and is the real answer at scale. Rejected
here for the reasons in [ADR-0009](0009-scaffold-cli-not-backstage.md), and
because it makes onboarding debuggable only through composition status.

**Version the template with a floating `template-v1` tag, mirroring the
pipeline.** Symmetrical, and tempting for that reason alone. Rejected because
the symmetry is false: a tag can only float over something that is *referenced*
at use time, and a rendered copy is read once. The tag would describe what the
scaffold last emitted, not what any service currently runs — a version number
that cannot drift because it is not connected to anything.
