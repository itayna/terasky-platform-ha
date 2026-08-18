#!/bin/bash
set -euo pipefail

CLUSTER_NAME="kind-dev"
ARGOCD_VERSION="v2.12.3"
SEALED_SECRETS_VERSION="v0.27.1"
KYVERNO_CHART_VERSION="3.8.2"

echo "==> Bootstrapping ${CLUSTER_NAME}"

# Create cluster if not exists
if ! kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo "==> Creating kind cluster ${CLUSTER_NAME}"
  kind create cluster --config "$(dirname "$0")/kind-config.yaml"
else
  echo "==> Cluster ${CLUSTER_NAME} already exists"
fi

# Install ArgoCD
echo "==> Installing ArgoCD ${ARGOCD_VERSION}"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "==> Waiting for ArgoCD to be ready"
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Install Sealed Secrets
echo "==> Installing Sealed Secrets ${SEALED_SECRETS_VERSION}"
kubectl apply -f "https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/controller.yaml"

echo "==> Waiting for Sealed Secrets controller"
kubectl wait --for=condition=available --timeout=300s deployment/sealed-secrets-controller -n kube-system

# Install Kyverno
echo "==> Installing Kyverno ${KYVERNO_CHART_VERSION}"
kubectl create namespace kyverno --dry-run=client -o yaml | kubectl apply -f -
helm repo add kyverno https://kyverno.github.io/kyverno/ || true
helm repo update
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno \
  --version "${KYVERNO_CHART_VERSION}" \
  --wait

echo "==> Waiting for Kyverno to be ready"
kubectl wait --for=condition=available --timeout=300s deployment/kyverno-admission-controller -n kyverno

# Apply Kyverno image signature verification policy
echo "==> Applying Kyverno image signature policy"
kubectl apply -f "$(dirname "$0")/../policies/verify-image-signatures.yaml"

# Get ArgoCD admin password
echo ""
echo "==> Bootstrap complete for ${CLUSTER_NAME}"
echo "==> ArgoCD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
echo "==> Port-forward ArgoCD UI: kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "==> Access: https://localhost:8080 (admin / <password above>)"
