# FUTURE — what I'd do next, and where I'd spend money

Honest status first: the paved road is built. The pipeline is one versioned
reusable workflow ([ADR-0008](docs/adr/0008-reusable-workflow-central-pipeline.md)),
onboarding is one command and a merged PR
([ADR-0009](docs/adr/0009-scaffold-cli-not-backstage.md)), and the platform bar is
asserted daily by `bin/scorecard` into [CATALOG.md](CATALOG.md) with a non-zero
exit on any red row. What follows is ordered by what I would actually do next, not
by what sounds most impressive.

## Next, in order

**1. Replace the health-check canary signal with real metrics.** The current
`ClusterAnalysisTemplate` polls `/actuator/health`. A release that 500s on the
business endpoint while Actuator reports `UP` passes the canary — the largest
known hole in the rollback story ([ADR-0003](docs/adr/0003-argo-rollouts.md)).
Fix: `micrometer-registry-prometheus` in the app, Prometheus scraping both stable
and canary, and a Rollouts `prometheus` provider metric on error rate and p95
latency. The assignment puts full monitoring stacks out of scope, so I did not
build it; it is the first thing I would add afterwards, because the abort
condition is what makes progressive delivery worth its complexity. It is also
what the AI promotion briefing ([docs/ai-capability.md](docs/ai-capability.md))
is waiting for: a briefing about what to watch is thin when there is one signal.

**2. Verify the SBOM, not just produce it.** The SBOM is generated and attached
today, and nothing downstream reads it — the scorecard checks it exists, which is
weaker than admission checking it. Adding `cosign attest` for the SPDX document
plus a Kyverno `verifyImages.attestations` rule would make "this image has a
provenance document produced by the platform pipeline" an admission requirement
rather than a CI artefact. Small change, real increase in what the attestation
story proves — and with the pipeline centralised it is one commit plus a tag move
for every service at once, which is the cheapest demonstration that
centralisation paid for itself.

**3. One namespace per service.** Every service currently deploys into `default`,
so nothing stops one team's manifest from naming another's object, and there are
no per-service resource quotas or NetworkPolicies. The templates already
parameterise the name, so this is a template change plus a `namespace` field in
each child Application — worth doing before service #3, not after.

**4. Infrastructure self-service.** A Crossplane `XRD` + composition exposing a
`PostgresClaim`, backed by an in-cluster StatefulSet locally and by a managed
database in a real environment, so the same claim works both places. This is the
next thing `platformctl` cannot do: it puts a service on the road, but a service
that needs a database still needs a human. Rejected as the onboarding API itself
([ADR-0009](docs/adr/0009-scaffold-cli-not-backstage.md)); it earns its place the
moment a service needs a bucket or a database.

**5. Bootstrap the platform components via Argo CD (app-of-apps).** Today
`bootstrap.sh` installs Argo CD, sealed-secrets and Kyverno imperatively — the
one place this platform is not GitOps-managed. Services already register through
an app-of-apps root; the components do not. Bootstrapping Argo CD first and
letting it manage the rest makes component versions a reviewable diff and
component drift self-healing. I left it imperative because a chicken-and-egg
bootstrap script that also has to be readable in a review is a poor trade at two
clusters; at three I would change my mind.

**6. A scorecard that can propose the fix.** Today a red row tells a team what
broke and the RUNBOOK tells them how to fix it. The obvious next step is for the
scorecard to open the pull request — restoring a drifted `delivery.yml` from the
template is mechanical. I would build this only after the bar has been stable
long enough that a wrong automated PR is rarer than a right one.

**7. Implement the AI promotion briefing.** Specified in
[docs/ai-capability.md](docs/ai-capability.md), deliberately unbuilt: its output
is prose, its value depends on reviewer behaviour, and it is worth much more once
item 1 gives it real signals to reason about.

## Things I deliberately did not do

- **Backstage.** Reasoned in
  [ADR-0009](docs/adr/0009-scaffold-cli-not-backstage.md): it would package this
  capability, not create it. The trigger to revisit is stated there — enough
  services that a markdown table is unreadable, or a team that will not use a CLI.
- **Service mesh, multi-cluster control plane, HA control planes.** Out of scope
  per the assignment, and none of them change the delivery story being
  demonstrated.
- **Flux instead of Argo CD** — reasoned in
  [ADR-0007](docs/adr/0007-argocd-vs-flux.md). If this grew to many clusters with
  no human watching a UI, that decision flips.
- **A staging environment.** A third environment would have added a copy of an
  existing pattern, not a new one. The promotion mechanism is identical.
- **Template migration tooling.** Templates are copies, versioned by directory,
  and a golden-path change reaches existing services by a reviewed pull request
  rather than reconciliation — deliberately, and for reasons that differ from the
  pipeline's floating tag ([ADR-0012](docs/adr/0012-template-versioning.md)). A
  version stamp on generated Applications, a Template column in the scorecard and
  a `platformctl upgrade` are the next step, and the ADR names the trigger.
- **Gradual rollout of a pipeline release.** A bad `v1` reaches every service at
  once; the mitigation is immutable `v1.x` tags and a tag-move rollback
  ([ADR-0010](docs/adr/0010-pipeline-version-tags.md)). Canarying a pipeline
  version across services is real work and only pays off at more services than
  this platform has.

## Where I'd spend money

Free tooling is the right answer at one service and the wrong answer at fifty.
Each row below is: the paid thing, what it replaces, and the pain that triggers
buying it.

| Paid tool | Replaces | Trigger to buy |
|---|---|---|
| **GitHub Actions larger runners / self-hosted pool** | free-tier runners | The first time the 2,000 min/month cap or 10-minute arm64 emulated builds gate merges. Cheapest possible win: engineer minutes are the most expensive thing in the pipeline. |
| **A hosted secret manager (AWS/GCP Secrets Manager, or Vault) behind External Secrets Operator** | sealed-secrets ([ADR-0004](docs/adr/0004-sealed-secrets.md)) | The first credential rotation across N services, or the first cluster rebuild where a lost controller key means re-sealing everything. Buying here removes a class of unrecoverable state. |
| **Datadog / Grafana Cloud** | self-hosted Prometheus (item 1 above) | When the team is on call and nobody wants to be paged about the monitoring stack itself. The value is not the dashboards, it is not operating the thing that watches everything else. |
| **Snyk / Wiz / Chainguard Images** | Trivy CVE gates | When "fail on CRITICAL" becomes noise the team routes around — a paid scanner buys reachability analysis and curated severity, i.e. fewer false blocks. Chainguard specifically buys a base image with near-zero CVEs, which removes most of the argument. |
| **Backstage-as-a-service (Roadie / Spotify Portal)** | `platformctl` + `CATALOG.md` | Around 20+ services or when non-platform engineers need to self-serve without reading a repository. Below that, running Backstage costs more than the friction it removes. |
| **Argo CD enterprise support (Akuity / Codefresh)** | self-operated Argo CD | When Argo CD becomes the thing that must not be down — multi-cluster, many teams. What is bought is an upgrade path and someone to call, not features. |

Ordering matters more than the list: runners first (immediate, small, unblocks
everyone), secrets second (removes unrecoverable failure modes), observability
third (makes progressive delivery real), portal last (it is packaging, and it is
the easiest to buy prematurely).
