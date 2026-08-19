# Deployment Guide

Image promotion workflow from dev to prod.

Every command below is per service. Set it once:

```bash
SERVICE=java-sample-app
```

## Overview

Automated CI pipeline (the shared reusable workflow in `platform-workflows`,
called by each service's three-line `delivery.yml`):
1. Build + test on push to `main`
2. Trivy scan for vulnerabilities
3. Build and push image to GHCR with SHA tag
4. Sign image with Cosign (keyless)
5. Update `terasky-platform-ha/environments/dev/$SERVICE/kustomization.yaml` with new tag
6. Commit and push to trigger ArgoCD sync

Manual prod promotion:
1. Open PR from dev tag to prod tag in `terasky-platform-ha`
2. Review PR
3. Merge → ArgoCD syncs prod → Argo Rollouts starts canary

## Dev Deployment (Automatic)

Triggered by push to `java-sample-app:main`.

Monitor via ArgoCD UI or CLI:

```bash
kubectl config use-context kind-kind-dev
kubectl argo cd app get java-sample-app-dev
kubectl argo cd app sync java-sample-app-dev --prune
```

Check pod rollout:

```bash
kubectl get pods -w
```

Verify deployment:

```bash
curl http://localhost:8080
curl http://localhost:8080/welcome
```

## Prod Promotion (Manual PR)

After dev deployment succeeds and testing passes.

### 1. Create promotion PR

```bash
cd terasky-platform-ha
git checkout -b promote-to-prod-<sha>

# Copy dev tag to prod
DEV_TAG=$(yq eval '.images[0].newTag' environments/dev/$SERVICE/kustomization.yaml)
yq eval ".images[0].newTag = \"$DEV_TAG\"" -i environments/prod/$SERVICE/kustomization.yaml

git add environments/prod/$SERVICE/kustomization.yaml
git commit -m "promote $DEV_TAG to prod"
git push -u origin promote-to-prod-<sha>

gh pr create --title "Promote $DEV_TAG to prod" --body "Promoting image $DEV_TAG from dev to prod"
```

### 2. Review PR

Check:
- Image tag matches successful dev deployment
- Image signature exists (cosign verify)
- Trivy scan passed in CI

### 3. Merge PR

```bash
gh pr merge <PR_NUMBER> --squash
```

### 4. Monitor canary rollout

```bash
kubectl config use-context kind-kind-prod
kubectl argo rollouts get rollout java-sample-app --watch
```

Canary steps:
- 20% traffic for 2 minutes
- 40% traffic for 2 minutes
- 60% traffic for 2 minutes
- 80% traffic for 2 minutes
- 100% (promote)

Health checks run every 30s during canary. 3 consecutive failures trigger auto-abort.

### 5. Manual canary control

Promote immediately (skip remaining steps):

```bash
kubectl argo rollouts promote java-sample-app
```

Abort canary (rollback):

```bash
kubectl argo rollouts abort java-sample-app
```

Retry after abort:

```bash
kubectl argo rollouts retry java-sample-app
```

## Verification

### Dev

```bash
kubectl config use-context kind-kind-dev
kubectl get pods
kubectl describe pod <pod-name> | grep Image:
curl http://localhost:8080
```

### Prod

```bash
kubectl config use-context kind-kind-prod
kubectl argo rollouts status java-sample-app
kubectl get pods -l app=java-sample-app
curl http://localhost:9080
curl http://localhost:9080/actuator/health
```

## Troubleshooting

**CI workflow fails at Trivy scan**: Check vulnerability report in Actions logs. Fix vulnerabilities in base image or dependencies, then re-run.

**CI workflow fails at Cosign sign**: Check OIDC token validity. Ensure GitHub Actions has `id-token: write` permission.

**ArgoCD not syncing after tag update**: Force refresh:

```bash
kubectl argo cd app sync <app-name> --force
```

**Rollout stuck in canary**: Check analysis job logs:

```bash
kubectl logs -l analysisrun=$(kubectl get analysisrun -o name | tail -1 | cut -d/ -f2)
```

Common causes:
- Health endpoint returning non-200
- Actuator not enabled (needs `spring-boot-starter-actuator`)
- Pod not ready (check readiness probe)
