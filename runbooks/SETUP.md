# SETUP — from nothing to a running platform

`make bootstrap` creates both `kind` clusters and installs the platform
components. It deliberately stops there, because the next three steps each need
a credential that is not, and must not be, in this repository:

| Step | Why it is not in `make bootstrap` |
|---|---|
| Seal the GHCR pull secret | It is encrypted to a cluster's own key, which does not exist until that cluster does ([ADR-0004](../docs/adr/0004-sealed-secrets.md)) |
| Give Argo CD read access to this repository | An SSH deploy key you hold; committing it would defeat the point |
| Register the two root Applications | Once per cluster, ever — and only once the two credentials above exist |

Order matters. Registering the roots first gives you two Argo CD instances that
cannot read the repository, syncing services that cannot pull images.

## Prerequisites

- Docker, `kind`, `kubectl`, `helm`
- `kubeseal` (`brew install kubeseal`) — sealing the pull secret
- `cosign` — verifying signatures by hand, and `bin/scorecard`
- `gh`, authenticated — `bin/platformctl`, `bin/scorecard`
- A GitHub PAT with `read:packages`, for the GHCR pull secret
- An SSH keypair for Argo CD's read access to this repository

## 1. Clusters and platform components

```bash
make bootstrap
```

Per cluster: Argo CD `v2.12.3`, sealed-secrets `v0.27.1`, Kyverno chart `3.8.2`
(app `v1.18.2` — the two numbering schemes are not the same, and confusing them
has already cost one failed bootstrap), and the signature `ClusterPolicy` from
`clusters/policies/`. `kind-prod` additionally gets Argo Rollouts `v1.9.1`.

Idempotent: existing clusters are reused, components are
`helm upgrade --install` / `kubectl apply`. Safe to re-run.

## 2. Seal the GHCR pull secret — once per cluster, every time

Each cluster's sealed-secrets controller generates its own keypair on first
start. The `SealedSecret` files already committed under
`environments/<env>/_platform/` were sealed for **the clusters that produced
them**. A cluster you just created cannot decrypt them, and the failure is a
silent `ImagePullBackOff` rather than an error — the controller simply never
creates the `Secret`.

So: after any fresh `make bootstrap`, re-seal both, or nothing pulls.

```bash
# dev
kubectl config use-context kind-kind-dev
kubectl create secret docker-registry ghcr-pull-secret \
  --namespace default \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<github-pat-with-read:packages> \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace kube-system \
           --controller-name sealed-secrets-controller \
           --format yaml \
> environments/dev/_platform/sealed-secret-ghcr.yaml
```

Repeat for prod with `kind-kind-prod` and `environments/prod/_platform/`.

Then commit and push. Argo CD deploys from the repository, not from your
working tree — an unpushed reseal changes nothing in either cluster:

```bash
git add environments/*/_platform/sealed-secret-ghcr.yaml
git commit -m "reseal ghcr pull secret for rebuilt clusters"
git push
```

## 3. Argo CD's read access to this repository

```bash
gh repo deploy-key add ~/.ssh/platform_key.pub \
  --repo itayna/terasky-platform-ha --title argocd-read
make repo-secret DEPLOY_KEY=~/.ssh/platform_key
```

Read-only is enough. The pipeline's *write* key
(`PLATFORM_REPO_DEPLOY_KEY`, held as a secret in each service repository) is a
separate credential — see
[RUNBOOK.md](../RUNBOOK.md#rotating-the-ci-deploy-key).

## 4. Register the root Applications

```bash
make apps
```

Once per cluster, ever. After this, services register themselves through Git:
the root app-of-apps watches `gitops/argocd-apps/<env>/`, so adding a child
`Application` file is the registration ([ADR-0009](../docs/adr/0009-scaffold-cli-not-backstage.md)).

## 5. Verify

```bash
make status      # sync + health for both environments, plus pods
make passwords   # the generated Argo CD admin passwords
```

Expect, within a sync interval (~3 min):

- dev: five Applications `Synced`/`Healthy`, six pods `Running`
- prod: `java-sample-app-prod` `Synced`/`Healthy`; the two services that have
  never been promoted are `Synced`/`Degraded` on `newTag:
  awaiting-first-promotion`. That is Kyverno denying a Pod whose image does not
  exist — the policy failing closed, and the correct state, not a fault.

Policy is live:

```bash
kubectl get clusterpolicy verify-image-signatures -o jsonpath='{.status.ready}{"\n"}'
```

The Argo CD UI needs a port-forward. **Not on 8080 or 9080** — `kind` already
publishes those host ports to the clusters' NodePorts (see
`clusters/kind-*/kind-config.yaml`), so a port-forward there fails with
`address already in use`:

```bash
kubectl --context kind-kind-dev  -n argocd port-forward svc/argocd-server 8081:443
kubectl --context kind-kind-prod -n argocd port-forward svc/argocd-server 9081:443
```

The application itself is reachable on the ports `kind` does publish:

```bash
curl http://localhost:8080            # java-sample-app in dev
curl http://localhost:9080/actuator/health   # java-sample-app in prod
```

Only `java-sample-app` has a `NodePort`; services created by `platformctl` are
`ClusterIP` and are reached with `kubectl port-forward`.

## Rebuilding after the clusters are gone

`kind delete cluster`, a Docker prune, or a laptop rebuild loses both clusters
*and* both sealed-secrets keypairs. There is nothing to restore unless you
backed the keys up ([RUNBOOK.md](../RUNBOOK.md#backing-up-the-sealed-secrets-key));
without them, the full path is:

```bash
make bootstrap                                   # 1
#   reseal both pull secrets, commit, push       # 2  ← the step people skip
make repo-secret DEPLOY_KEY=~/.ssh/platform_key  # 3
make apps                                        # 4
make status                                      # 5
```

Nothing else has to be recreated: every service, Application and image tag is
already in Git, and Argo CD reconciles the clusters back to it. That is the
property worth demonstrating — the clusters are disposable, the repository is
not.

## Troubleshooting

Day-2 procedures — a stuck deploy, admission denials, `ImagePullBackOff`, a
paused canary, component upgrades, break-glass — are in
[RUNBOOK.md](../RUNBOOK.md). Deploying and promoting a change is
[DEPLOY.md](DEPLOY.md); rolling one back is [ROLLBACK.md](ROLLBACK.md).
