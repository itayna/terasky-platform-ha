# TeraSky Platform — a paved road for Java services

Clusters, GitOps state, admission policy and the tooling that puts a new service
on all of it: one command and a merged pull request, with no platform-team action.
What is on the road and whether it still complies is [CATALOG.md](CATALOG.md).

The delivery pipeline itself lives in
[`itayna/platform-workflows`](https://github.com/itayna/platform-workflows) and is
shared by every service ([ADR-0008](docs/adr/0008-reusable-workflow-central-pipeline.md)).
Application source lives in one repository per service — see
[ADR-0001](docs/adr/0001-two-repositories.md) for why deploy state is split from it.

Everything here runs on free, open-source tooling against local `kind` clusters.

## Architecture

```
 developer push to main                          ┌───────────────────────────────┐
          │                                      │ platform-workflows (public)   │
          ▼                                      │  java-service-delivery.yml @v1│
┌──────────────────────────────────┐  uses: @v1  │                               │
│ <service> repo    delivery.yml   │────────────▶│ lint+test ─▶ Trivy fs         │
│  (3 lines: uses + service-name)  │             │ buildx amd64+arm64 ─▶ Trivy   │
└──────────────────────────────────┘             │ SBOM (SPDX) ─▶ cosign sign    │
                                                 │ commit dev tag ──────────┐    │
                                                 └──────────────────────────┼────┘
┌────────────────────────────────────────────────────────────────────────◀──┘
│ terasky-platform-ha (private) — this repo, the only deploy input
│
│  environments/dev/<service>    Deployment, 2 replicas
│  environments/prod/<service>   Rollout, canary 20/40/60/80 + analysis
│  environments/<env>/_platform  GHCR pull secret, canary criteria (shared)
│  gitops/argocd-apps/<env>/     one child Application per service
│
│  promote-prod.yml   manual dispatch ─▶ cosign verify ─▶ PR   (never automatic)
│  scorecard.yml      daily ─▶ CATALOG.md, red row fails the check
└──────────────────────────────────────────────────────────────────────────────┘
        │ Argo CD pulls (SSH deploy key, self-heal + prune)
        ├──────────────────────────────┐
        ▼                              ▼
┌──────────────────────┐      ┌──────────────────────────┐
│ kind-dev             │      │ kind-prod                │
│  Argo CD (root app)  │      │  Argo CD (root app)      │
│  sealed-secrets      │      │  sealed-secrets          │
│  Kyverno ── verify ──┤      │  Kyverno ── verify ──────┤ cosign identity
│                      │      │  Argo Rollouts           │ must match, or
│  Deployment/service  │      │  Rollout/service (canary)│ admission denies
└──────────────────────┘      └──────────────────────────┘
```

Two clusters, not two namespaces: a namespace split cannot show a cluster-scoped
policy or controller upgrade going wrong in dev before prod
([ADR-0002](docs/adr/0002-kind-two-clusters.md)).

Each environment's root Application is an app-of-apps over
`gitops/argocd-apps/<env>/`, so adding a service is adding a file — not running
`kubectl` ([ADR-0009](docs/adr/0009-scaffold-cli-not-backstage.md)).

## Bootstrap

Requirements: Docker, `kind`, `kubectl`, `helm`, `kubeseal`, `cosign`, `gh`.

```bash
make bootstrap                                   # both clusters + platform components
make repo-secret DEPLOY_KEY=~/.ssh/platform_key  # Argo CD read access to this repo
make apps                                        # register the two root Applications
make status                                      # sync + health, all services
make passwords                                   # Argo CD admin passwords
```

`make bootstrap` is idempotent — existing clusters are reused, components are
`helm upgrade --install`/`kubectl apply`. `make apps` is once per cluster, ever:
after it, services register themselves through Git. Full manual walkthrough,
including sealing a fresh GHCR pull secret, is in
[runbooks/SETUP.md](runbooks/SETUP.md).

The GHCR pull secret is one `SealedSecret` per environment in
`environments/<env>/_platform/`, shared by every service. It only decrypts on the
cluster whose controller key sealed it, so a fresh bootstrap needs its own
`kubeseal` run — but onboarding does not, which is what keeps cluster credentials
out of the onboarding path ([ADR-0004](docs/adr/0004-sealed-secrets.md)).

## Onboarding a service

```bash
make onboard SERVICE=payments OWNER=some-handle    # or: bin/platformctl new payments
bin/platformctl new payments --dry-run             # prints the tree, touches nothing
```

One command, then one merged pull request. `platformctl` creates the service
repository from the reference app (working Java service, Actuator probes, a
three-line `delivery.yml` calling the shared pipeline), renders
`environments/{dev,prod}/payments/` and both child Applications from
`templates/service-v1/`, appends the service to `catalog/services.yaml`, and opens
the pull request. Merging it is the deployment: the root app-of-apps picks up the
new Application, Argo CD syncs, Kyverno verifies the signature.

| Step | Who | Platform team needed |
|---|---|---|
| `make onboard` | product team | no |
| review + merge the PR | a reviewer | no — any repo reviewer |
| push code to the service repo | product team | no |
| promote to prod | product team, via `promote-prod` + PR merge | no |

Nobody touched a cluster, and no file in this repository's `clusters/` or
`_platform/` changed.

## The catalog

[`CATALOG.md`](CATALOG.md) — what exists, who owns it, what is deployed where, and
whether it still meets the platform bar. Generated by `bin/scorecard`, which
derives every column from a source of truth (`CODEOWNERS`, the service's
`delivery.yml`, the registry, this repository's history) rather than storing a
second copy that can drift. `catalog/services.yaml` holds identity only.

It runs daily and on every push to `main`, and **exits non-zero on a red row**, so
falling off the bar is a failing check rather than a stale dashboard. Live state
stays the Argo CD UI.

## Guided tour: a commit reaching prod

1. **Commit** lands on `main` in the service repository.
2. **CI** is three lines of `uses:` pointing at
   `platform-workflows/.github/workflows/java-service-delivery.yml@v1`. It checks
   that `service-name` matches the calling repository — a `delivery.yml` copied
   from another service would otherwise build and sign that service's image name
   from this source — then runs `mvn -B verify`, which lints (Checkstyle, bound to
   `validate`) and tests, then a Trivy filesystem scan that fails the build on any
   CRITICAL finding.
3. **Image** is built with buildx for `linux/amd64` and `linux/arm64`, pushed to
   GHCR as `:<12-char-sha>` — never `:latest`, so every deployed state is
   addressable and revertable.
4. **Gates** on the image: Trivy image scan (CRITICAL = fail), SPDX SBOM
   generated and attached, then `cosign sign --yes` using the workflow's GitHub
   OIDC token. No long-lived signing key exists to steal
   ([ADR-0005](docs/adr/0005-cosign-keyless-kyverno.md)).
5. **Dev promotion** is automatic: the pipeline's last job commits
   `newTag: <sha>` into `environments/dev/<service>/kustomization.yaml` in this
   repo using a deploy key scoped to this repo only.
6. **Argo CD (dev)** sees the commit and syncs. `selfHeal: true` means a manual
   `kubectl edit` in the cluster is reverted, not preserved
   ([ADR-0007](docs/adr/0007-argocd-vs-flux.md)).
7. **Kyverno** intercepts pod admission and verifies the cosign signature against
   the pipeline's identity
   `https://github.com/itayna/platform-workflows/.github/workflows/java-service-delivery.yml@refs/tags/v*`.
   An image built by any other workflow is denied — including one built from a
   fork, and including one signed by a valid but different identity. The
   signature proves "built by version v1.x of the platform pipeline", which is
   the trade that lets onboarding add zero admission rules
   ([ADR-0008](docs/adr/0008-reusable-workflow-central-pipeline.md)).
8. **Prod promotion is a deliberate act.** CI never writes to
   `environments/prod`. An operator runs the `promote-prod` workflow with a
   service and a tag (default: whatever that service runs in dev); it re-verifies
   the signature and opens a PR. Merging the PR is the deploy
   ([ADR-0006](docs/adr/0006-promotion-flow.md)).
9. **Argo Rollouts (prod)** rolls the new tag out as a canary at 20/40/60/80%
   with a background `AnalysisRun` polling `/actuator/health` on the canary
   service every 30s. Three consecutive non-`UP` readings abort the rollout and
   scale the canary back down ([ADR-0003](docs/adr/0003-argo-rollouts.md)). The
   criteria are one `ClusterAnalysisTemplate` in `_platform`, so no team owns a
   copy of the platform's abort conditions.

## Shipping a change to every service's pipeline

Commit it in `platform-workflows`, tag `v1.x`, move the floating `v1`. Every
service picks it up on its next push with no edit in any service repository;
`CATALOG.md` reports who is pinned behind. Procedure and rollback:
[RUNBOOK.md](RUNBOOK.md), rationale: [ADR-0010](docs/adr/0010-pipeline-version-tags.md).

## Rollback

Full procedure, timings and the database-adjacent case:
[runbooks/ROLLBACK.md](runbooks/ROLLBACK.md).

Short version — three tiers, cheapest first:

| Situation | Action | Recovery |
|---|---|---|
| Bad canary, still rolling | `kubectl argo rollouts abort <service>` | seconds; canary pods drain, stable never left service |
| Bad image fully promoted | `kubectl argo rollouts undo <service>` | seconds; then revert the promotion PR so Git matches, or Argo CD self-heals back to the bad tag |
| Bad platform config | revert the commit in this repo | one sync interval (~3 min, or `argocd app sync`) |
| Bad pipeline release | `git tag -f v1 v1.<previous> && git push -f origin v1` | next push per service |

The second row is the trap worth stating out loud: the imperative undo is faster
than Git, but Git is the source of truth, so the revert commit must follow or
self-heal will undo the undo.

## Deliberately not built

Backstage ([ADR-0009](docs/adr/0009-scaffold-cli-not-backstage.md)), Crossplane
infrastructure claims, full monitoring stack, service mesh, multi-cluster control
plane, HA control planes. The canary's abort signal is the Actuator health
endpoint rather than Prometheus error-rate metrics; that tradeoff and what it
costs are in [FUTURE.md](FUTURE.md). The one AI capability designed for this
platform is specified and deliberately not implemented
([docs/ai-capability.md](docs/ai-capability.md)).

## Repository map

| Path | Contents |
|---|---|
| `bin/platformctl` | Onboarding: repo + manifests + Applications + catalog + PR |
| `bin/scorecard` | Asserts the platform bar per service, writes `CATALOG.md` |
| `catalog/services.yaml` | Service identity — the one hand-edited list |
| `templates/service-v1/` | The golden path: what a new service is rendered from ([ADR-0012](docs/adr/0012-template-versioning.md)) |
| `clusters/kind-{dev,prod}/` | `kind` config + bootstrap script per cluster |
| `clusters/policies/` | Kyverno `ClusterPolicy` (signature enforcement) |
| `gitops/argocd-apps/root-{dev,prod}.yaml` | App-of-apps roots — the only `kubectl apply` |
| `gitops/argocd-apps/{dev,prod}/` | One child `Application` per service |
| `environments/<env>/<service>/` | That service's manifests for that environment |
| `environments/<env>/_platform/` | Shared: GHCR pull secret, canary criteria |
| `.github/workflows/` | `promote-prod.yml` (prod gate), `scorecard.yml` (compliance) |
| `docs/adr/` | Architecture decision records |
| `docs/ai-capability.md` | The AI capability: design, trust boundary, failure modes |
| `runbooks/` | SETUP, DEPLOY, ROLLBACK |
| `RUNBOOK.md` | Platform-operator day-2 doc |
| `CATALOG.md` | Generated service catalog + compliance scorecard |
| `FUTURE.md` | What's next, and where I'd spend money |
| `AI_LOG.md` | How AI was used, what it got wrong, what I overrode |
