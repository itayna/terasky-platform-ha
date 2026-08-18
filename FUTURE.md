# FUTURE — what I'd do next, and where I'd spend money

Honest status first: Stage 1 is built and defensible. Stage 2 exists as a
documented bar (the table in [RUNBOOK.md](RUNBOOK.md#the-platform-bar-and-falling-off-it))
but not yet as machinery. The items below are ordered by what I would actually
do next, not by what sounds most impressive.

## Next, in order

**1. Centralise the pipeline (highest value per hour).** `delivery.yml` is a
per-repo file today. Adding a mandatory scan step means editing every service's
copy — the failure mode the assignment explicitly probes. Fix: move the whole
pipeline into a reusable workflow in a platform-owned repository, called by each
service with a three-line stub pinned to a tag (`@v1`). Adding a step then means
cutting `v1.1`; services on `@v1` pick it up, services pinned to `@v1.0` do not,
which is also the template-versioning answer. Callers stay auditable because the
`workflow_call` reference appears in the app repo's git history.

**2. A scaffold that produces service #2.** Concretely: a `platformctl new
<service>` script (or a `gh` extension) that creates the repository from a
template, drops in the three-line workflow stub, generates
`environments/{dev,prod}/<service>/` with the standard kustomization, registers
an Argo CD `Application`, and opens both PRs. Target is a service deployed by a
developer with zero platform-team involvement. A Backstage software template does
the same job with a UI on top; I would not run Backstage for one service — the
scaffold is the substance, the portal is packaging.

**3. Compliance as a check, not a convention.** Rows 4–6 of the platform bar are
currently enforced by someone reading a diff. A scheduled workflow that, per
service, asserts: image signature verifies, SBOM attestation exists, prod tag
matches a merged promotion PR, `CODEOWNERS` present, Actuator endpoints
reachable — writing results to a single markdown table in this repository. That
table is also the honest, lightweight version of a service catalog: what exists,
who owns it, what is deployed where, is it on the paved road.

**4. Replace the health-check canary signal with real metrics.** The current
`AnalysisTemplate` polls `/actuator/health`. A release that 500s on the business
endpoint while Actuator reports `UP` passes the canary — the largest known hole
in the rollback story ([ADR-0003](docs/adr/0003-argo-rollouts.md)). Fix:
`micrometer-registry-prometheus` in the app, Prometheus scraping both stable and
canary, and a Rollouts `prometheus` provider metric on error rate and p95 latency.
The assignment puts full monitoring stacks out of scope, so I did not build it;
it is the first thing I would add afterwards, because the abort condition is what
makes progressive delivery worth its complexity.

**5. Verify the SBOM, not just produce it.** The SBOM is generated and attached
today, and nothing downstream reads it. Adding `cosign attest` for the SPDX
document plus a Kyverno `verifyImages.attestations` rule would make "this image
has a provenance document produced by that workflow" an admission requirement
rather than a CI artefact. That is a small change with a real increase in what
the attestation story actually proves.

**6. Infrastructure self-service.** A Crossplane `XRD` + composition exposing a
`PostgresClaim`, backed by an in-cluster StatefulSet locally and by a managed
database in a real environment, so the same claim works both places. Even mocked,
it demonstrates the pattern that keeps database requests out of the platform
team's inbox.

**7. Bootstrap the platform components via Argo CD (app-of-apps).** Today
`bootstrap.sh` installs Argo CD, sealed-secrets and Kyverno imperatively — the
one place this platform is not GitOps-managed. Bootstrapping Argo CD first and
letting it manage the rest makes component versions a reviewable diff and
component drift self-healing. I left it imperative because a chicken-and-egg
bootstrap script that also has to be readable in a review is a poor trade for one
service; at three clusters I would change my mind.

## Things I deliberately did not do

- **Service mesh, multi-cluster control plane, HA control planes.** Out of scope
  per the assignment, and none of them change the delivery story being
  demonstrated.
- **Flux instead of Argo CD** — reasoned in
  [ADR-0007](docs/adr/0007-argocd-vs-flux.md). If this grew to many clusters with
  no human watching a UI, that decision flips.
- **A staging environment.** A third environment would have added a copy of an
  existing pattern, not a new one. The promotion mechanism is identical.

## Where I'd spend money

Free tooling is the right answer at one service and the wrong answer at fifty.
Each row below is: the paid thing, what it replaces, and the pain that triggers
buying it.

| Paid tool | Replaces | Trigger to buy |
|---|---|---|
| **GitHub Actions larger runners / self-hosted pool** | free-tier runners | The first time the 2,000 min/month cap or 10-minute arm64 emulated builds gate merges. Cheapest possible win: engineer minutes are the most expensive thing in the pipeline. |
| **A hosted secret manager (AWS/GCP Secrets Manager, or Vault) behind External Secrets Operator** | sealed-secrets ([ADR-0004](docs/adr/0004-sealed-secrets.md)) | The first credential rotation across N services, or the first cluster rebuild where a lost controller key means re-sealing everything. Buying here removes a class of unrecoverable state. |
| **Datadog / Grafana Cloud** | self-hosted Prometheus (item 4 above) | When the team is on call and nobody wants to be paged about the monitoring stack itself. The value is not the dashboards, it is not operating the thing that watches everything else. |
| **Snyk / Wiz / Chainguard Images** | Trivy CVE gates | When "fail on CRITICAL" becomes noise the team routes around — a paid scanner buys reachability analysis and curated severity, i.e. fewer false blocks. Chainguard specifically buys a base image with near-zero CVEs, which removes most of the argument. |
| **Backstage-as-a-service (Roadie / Spotify Portal)** | the scaffold + markdown catalog (items 2–3) | Around 20+ services or when non-platform engineers need to self-serve without reading a repository. Below that, running Backstage costs more than the friction it removes. |
| **Argo CD enterprise support (Akuity / Codefresh)** | self-operated Argo CD | When Argo CD becomes the thing that must not be down — multi-cluster, many teams. What is bought is an upgrade path and someone to call, not features. |

Ordering matters more than the list: runners first (immediate, small, unblocks
everyone), secrets second (removes unrecoverable failure modes), observability
third (makes progressive delivery real), portal last (it is packaging, and it is
the easiest to buy prematurely).
