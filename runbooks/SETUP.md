# Setup Guide

Complete cluster bootstrap procedure for dev and prod environments.

## Prerequisites

- Docker Desktop running
- `kind` installed
- `kubectl` installed
- `helm` installed
- `kubeseal` CLI installed (`brew install kubeseal`)
- GitHub CLI authenticated
- GitHub Personal Access Token with `read:packages` scope

## 1. Bootstrap Dev Cluster

```bash
cd clusters/kind-dev
./bootstrap.sh
```

Wait for completion. Script installs:
- ArgoCD v2.12.3
- Sealed Secrets controller v0.27.1
- Kyverno v1.12.5

Save ArgoCD admin password from output.

## 2. Bootstrap Prod Cluster

```bash
cd clusters/kind-prod
./bootstrap.sh
```

Wait for completion. Script installs same as dev plus:
- Argo Rollouts (latest)

Save ArgoCD admin password from output.

## 3. Seal GHCR Pull Secret

Create base secret:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<GITHUB_USERNAME> \
  --docker-password=<GITHUB_PAT> \
  --dry-run=client -o yaml > /tmp/ghcr-secret.yaml
```

### Dev cluster

```bash
kubectl config use-context kind-kind-dev
kubeseal --format yaml --cert <(kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml | yq eval '.items[0].data."tls.crt"' - | base64 -d) < /tmp/ghcr-secret.yaml > environments/dev/sealed-secret-ghcr.yaml
```

### Prod cluster

```bash
kubectl config use-context kind-kind-prod
kubeseal --format yaml --cert <(kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml | yq eval '.items[0].data."tls.crt"' - | base64 -d) < /tmp/ghcr-secret.yaml > environments/prod/sealed-secret-ghcr.yaml
```

Commit sealed secrets:

```bash
git add environments/*/sealed-secret-ghcr.yaml
git commit -m "add sealed ghcr pull secrets for dev and prod"
git push
```

## 4. Deploy ArgoCD Applications

### Dev

```bash
kubectl config use-context kind-kind-dev
kubectl apply -f gitops/argocd-apps/dev-app.yaml
```

### Prod

```bash
kubectl config use-context kind-kind-prod
kubectl apply -f gitops/argocd-apps/prod-app.yaml
```

## 5. Access ArgoCD UI

### Dev

```bash
kubectl config use-context kind-kind-dev
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open https://localhost:8080 (admin / password from bootstrap)

### Prod

```bash
kubectl config use-context kind-kind-prod
kubectl port-forward svc/argocd-server -n argocd 9080:443
```

Open https://localhost:9080 (admin / password from bootstrap)

## 6. Verify Deployment

### Dev

```bash
kubectl config use-context kind-kind-dev
kubectl get pods
kubectl get svc
curl http://localhost:8080
```

### Prod

```bash
kubectl config use-context kind-kind-prod
kubectl get rollouts
kubectl argo rollouts get rollout java-sample-app
curl http://localhost:9080
```

## Troubleshooting

**ArgoCD app stuck syncing**: Check image pull secret. Verify sealed secret decrypted correctly:

```bash
kubectl get secret ghcr-pull-secret -o yaml
```

**Pod ImagePullBackOff**: Verify GitHub PAT has `read:packages` scope. Recreate secret if needed.

**Kyverno blocking unsigned images**: Expected during initial setup. CI pipeline will sign images after first build.

**Rollout stuck in canary**: Check analysis job logs:

```bash
kubectl logs -l analysisrun=<run-name>
```
