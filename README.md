# TeraSky Platform — delivery pipeline for `java-sample-app`

Infrastructure, GitOps state and platform policy for the `java-sample-app` service.
Application source and its CI live in a separate repository,
[`itayna/java-sample-app`](https://github.com/itayna/java-sample-app) — see
[ADR-0001](docs/adr/0001-two-repositories.md) for why the split exists.

Everything here runs on free, open-source tooling against local `kind` clusters.

## Architecture

```
 developer push to main
          │
          ▼
┌──────────────────────────────────────────────────────────────┐
│ java-sample-app (public)   GitHub Actions: delivery.yml      │
│                                                              │
│  build+test ─▶ Trivy fs ─▶ buildx (amd64+arm64) ─▶ Trivy img │
│                              │                               │
│                              ├─▶ SBOM (SPDX) ─▶ attached     │
│                              └─▶ cosign sign (keyless, OIDC) │
│                                        │                     │
│                              ghcr.io/itayna/java-sample-app  │
│                                        │                     │
│  promote-dev: commit `newTag: <sha12>` to environments/dev ──┼──┐
└──────────────────────────────────────────────────────────────┘  │
                                                                  │
┌─────────────────────────────────────────────────────────────────▼┐
│ terasky-platform-ha (private) — this repo, the only deploy input │
│                                                                  │
│  environments/dev   Deployment, 2 replicas                       │
│  environments/prod  Rollout, canary 20/40/60/80 + analysis       │
│                                                                  │
│  promote-prod.yml   manual dispatch ─▶ cosign verify ─▶ PR       │
└──────────────────────────────────────────────────────────────────┘
        │ Argo CD pulls (SSH deploy key, self-heal + prune)
        ├──────────────────────────────┐
        ▼                              ▼
┌──────────────────────┐      ┌──────────────────────────┐
│ kind-dev             │      │ kind-prod                │
│  Argo CD             │      │  Argo CD                 │
│  sealed-secrets      │      │  sealed-secrets          │
│  Kyverno ── verify ──┤      │  Kyverno ── verify ──────┤ cosign identity
│                      │      │  Argo Rollouts           │ must match, or
│  Deployment (2)      │      │  Rollout (3, canary)     │ admission denies
└──────────────────────┘      └──────────────────────────┘
```

Two clusters, not two namespaces: a namespace split cannot show a cluster-scoped
policy or controller upgrade going wrong in dev before prod
([ADR-0002](docs/adr/0002-kind-two-clusters.md)).

## Bootstrap

Requirements: Docker, `kind`, `kubectl`, `helm`, `kubeseal`, `cosign`, `gh`.

```bash
make bootstrap                                   # both clusters + platform components
make repo-secret DEPLOY_KEY=~/.ssh/platform_key  # Argo CD read access to this repo
make apps                                        # register dev + prod Applications
make status                                      # sync + health
make passwords                                   # Argo CD admin passwords
```

`make bootstrap` is idempotent — existing clusters are reused, components are
`helm upgrade --install`/`kubectl apply`. Full manual walkthrough, including
sealing a fresh GHCR pull secret, is in [runbooks/SETUP.md](runbooks/SETUP.md).

The GHCR pull secret is committed as a `SealedSecret` per environment. It only
decrypts on the cluster whose controller key sealed it, so a fresh bootstrap
needs its own `kubeseal` run ([ADR-0004](docs/adr/0004-sealed-secrets.md)).

## Guided tour: a commit reaching prod

1. **Commit** lands on `main` in `java-sample-app`.
2. **CI** (`delivery.yml`) runs `mvn -B verify`, then a Trivy filesystem scan
   that fails the build on any CRITICAL finding.
3. **Image** is built with buildx for `linux/amd64` and `linux/arm64`, pushed to
   GHCR as `:<12-char-sha>` — never `:latest`, so every deployed state is
   addressable and revertable.
4. **Gates** on the image: Trivy image scan (CRITICAL = fail), SPDX SBOM
   generated and attached, then `cosign sign --yes` using the workflow's GitHub
   OIDC token. No long-lived signing key exists to steal
   ([ADR-0005](docs/adr/0005-cosign-keyless-kyverno.md)).
5. **Dev promotion** is automatic: the pipeline's last job commits
   `newTag: <sha>` into `environments/dev/kustomization.yaml` in this repo using
   a deploy key scoped to this repo only.
6. **Argo CD (dev)** sees the commit and syncs. `selfHeal: true` means a manual
   `kubectl edit` in the cluster is reverted, not preserved
   ([ADR-0007](docs/adr/0007-argocd-vs-flux.md)).
7. **Kyverno** intercepts pod admission and verifies the cosign signature
   against the exact identity
   `https://github.com/itayna/java-sample-app/.github/workflows/delivery.yml@refs/heads/main`.
   An image built by any other workflow, repo or branch is denied — including one
   built from a fork, and including one signed by a valid but different identity.
8. **Prod promotion is a deliberate act.** CI never writes to
   `environments/prod`. An operator runs the `promote-prod` workflow with a tag
   (default: whatever dev currently runs); it re-verifies the signature and opens
   a PR. Merging the PR is the deploy
   ([ADR-0006](docs/adr/0006-promotion-flow.md)).
9. **Argo Rollouts (prod)** rolls the new tag out as a canary at 20/40/60/80%
   with a background `AnalysisRun` polling `/actuator/health` on the canary
   service every 30s. Three consecutive non-`UP` readings abort the rollout and
   scale the canary back down ([ADR-0003](docs/adr/0003-argo-rollouts.md)).

## Rollback

Full procedure, timings and the database-adjacent case:
[runbooks/ROLLBACK.md](runbooks/ROLLBACK.md).

Short version — three tiers, cheapest first:

| Situation | Action | Recovery |
|---|---|---|
| Bad canary, still rolling | `kubectl argo rollouts abort java-sample-app` | seconds; canary pods drain, stable never left service |
| Bad image fully promoted | `kubectl argo rollouts undo java-sample-app` | seconds; then revert the promotion PR so Git matches, or Argo CD self-heals back to the bad tag |
| Bad platform config | revert the commit in this repo | one sync interval (~3 min, or `argocd app sync`) |

The middle row is the trap worth stating out loud: the imperative undo is faster
than Git, but Git is the source of truth, so the revert commit must follow or
self-heal will undo the undo.

## Deliberately not built

Full monitoring stack, service mesh, multi-cluster control plane, HA control
planes — out of scope per the assignment. The canary's abort signal is the
Actuator health endpoint rather than Prometheus error-rate metrics; that
tradeoff and what it costs are in [FUTURE.md](FUTURE.md).

## Repository map

| Path | Contents |
|---|---|
| `clusters/kind-{dev,prod}/` | `kind` config + bootstrap script per cluster |
| `clusters/policies/` | Kyverno `ClusterPolicy` (signature enforcement) |
| `gitops/argocd-apps/` | Argo CD `Application` per environment |
| `environments/dev/` | Deployment, Service, sealed GHCR secret, kustomization |
| `environments/prod/` | Rollout, Services (stable+canary), AnalysisTemplate, sealed secret |
| `.github/workflows/` | `promote-prod.yml` — the prod promotion gate |
| `docs/adr/` | Architecture decision records |
| `runbooks/` | SETUP, DEPLOY, ROLLBACK |
| `RUNBOOK.md` | Platform-operator day-2 doc |
| `FUTURE.md` | What's next, and where I'd spend money |
| `AI_LOG.md` | AI usage log |
