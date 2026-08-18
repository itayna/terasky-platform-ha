# Stage 1 — Delivery Engineering Design Spec

## Executive Summary
This document specifies the delivery cluster architecture and container supply-chain security pipelines for the `java-sample-app`. The goal is a resilient GitOps pipeline targeting two Kubernetes environments (`dev`, `prod`) run on private local clusters, utilizing open-source components with zero cost footprint.

---

## 1. System Architecture
The application runs across two separate Kubernetes clusters hosted locally via `kind`:
- **`kind-dev`**: Runs the development version of the application. Builds are automatically synced from Git.
- **`kind-prod`**: Runs the production version. Deploys are gradual (canary) and human-gated via Git Pull Requests.

```
                  +--------------------------------+
                  |    GitHub Actions Pipeline     |
                  +---------------+----------------+
                                  |
            1. Build & Push       | 2. Sign Image (Fulcio/Rekor)
            +---------------------+---------------------+
            |                                           |
            v                                           v
+-----------+-----------+                      +--------+--------+
| GHCR Public Registry  |                      | itayna/java-    |
| (signed images)       |                      | sample-app      |
+-----------+-----------+                      | (public fork)   |
            ^                                   +--------+--------+
            |                                            |
            | (pulls signed image)                       | (CI updates tag)
            |                                            v
    +-------+-------+                           +--------+--------+
    |   kind-dev    |                           | terasky-        |
    |   cluster     | <-------------------------+ platform-ha     |
    +---------------+     3. ArgoCD reconcile    | (private repo)  |
                          dev manifests          +--------+--------+
                                                          |
                                                          | 4. ArgoCD reconcile
                                                          |    prod manifests
                                                          v
                                                 +-------+-------+
                                                 |   kind-prod   |
                                                 |   cluster     |
                                                 +---------------+
```

**Repository Split:**
- **`itayna/java-sample-app` (public fork)**: Application source code, `Dockerfile`, GitHub Actions CI workflow only.
- **`terasky-platform-ha` (private)**: All GitOps manifests, ArgoCD applications, Sealed Secrets, cluster bootstrap scripts, design specs, runbooks.

---

## 2. Supply-Chain Security & CI Pipeline (GitHub Actions)
The execution workflow triggers on push to the `main` branch in `itayna/java-sample-app`:

1. **Lint & Test**:
   - Compiles Spring Boot application via Maven.
   - Runs JUnit tests (`mvn test`).
2. **Container Build**:
   - Multi-stage `Dockerfile` (Maven builder + minimal eclipse-temurin:25 Alpine JRE).
   - Generates OCI container image.
3. **Vulnerability Scan**:
   - Scans image via **Trivy** (`aquasecurity/trivy-action`).
   - Pinning: Trivy action pinned to a verified SHA digest (mitigating the March 2026 release hijack threat).
   - Policy: Build breaks if any `CRITICAL` vulnerability is detected.
4. **SBOM Generation**:
   - Trivy outputs a CycloneDX SBOM file.
   - SBOM is uploaded as a GitHub Actions run artifact.
5. **Image Signing & Attestation**:
   - Signed using **Cosign keyless mode** (Sigstore).
   - Uses GitHub Actions' OIDC token provider to verify builder identity (Fulcio) and logs verification entries to the public Rekor transparency log.
   - Pinning: cosign binary pinned to version `v2.6.2` to bypass the Rekor-checking CVE discovered in early 2026.
   - The signed image is pushed to GitHub Container Registry (GHCR) as `ghcr.io/itayna/java-sample-app:sha-<git-commit-hash>`.
6. **Manifest Update**:
   - CI workflow clones `terasky-platform-ha` (private repo) using a GitHub Deploy Key.
   - Updates `environments/dev/kustomization.yaml` with the new image tag.
   - Commits and pushes the change back to `terasky-platform-ha`.

---

## 3. GitOps Layout & Reconciler (ArgoCD)
A dedicated Git folder structure in `terasky-platform-ha` governs cluster configuration state:

```
terasky-platform-ha/
├── docs/
│   └── superpowers/
│       └── specs/
│           └── 2026-08-16-stage1-delivery-design.md
├── environments/
│   ├── dev/
│   │   ├── kustomization.yaml
│   │   ├── deployment.yaml
│   │   └── sealed-secret-ghcr.yaml
│   └── prod/
│       ├── kustomization.yaml
│       ├── rollout.yaml              # Argo Rollout canary spec
│       ├── service.yaml
│       └── sealed-secret-ghcr.yaml
├── gitops/
│   └── argocd-apps/
│       ├── dev-app.yaml              # Argo Application targeting kind-dev
│       └── prod-app.yaml             # Argo Application targeting kind-prod
├── clusters/
│   ├── kind-dev/
│   │   ├── kind-config.yaml
│   │   └── bootstrap.sh              # Install ArgoCD, Sealed Secrets, Kyverno
│   └── kind-prod/
│       ├── kind-config.yaml
│       └── bootstrap.sh
└── runbooks/
    ├── SETUP.md                      # Cluster bootstrap instructions
    ├── DEPLOY.md                     # Promotion workflow
    └── ROLLBACK.md                   # Rollback procedures
```

### Git Private Auth & Pull Secrets
Because the container images are public but GitOps manifests are private:
- **Git Repository Access**: ArgoCD uses a Deploy Key with read-only access to pull manifests from `terasky-platform-ha`.
- **GHCR Registry Pull Secret**: Not required for public images. If images become private later, a Kubernetes `Secret` of type `kubernetes.io/dockerconfigjson` containing a GitHub Personal Access Token (PAT) with `read:packages` scope will be needed.

---

## 4. Secret Management (Bitnami Sealed Secrets)
To avoid committing raw secrets to Git:
- **Bitnami Sealed Secrets** is installed on both clusters.
- Any application secrets or credentials are sealed locally using `kubeseal` targeting the cluster's public sealing key.
- The resulting `SealedSecret` manifests are safe to commit to the private `terasky-platform-ha` repo.
- **Rotation**: Covered in `runbooks/SECRETS.md`. Regenerating a secret requires resealing using each cluster's respective key and pushing a Git commit.

---

## 5. Admission Policy (Kyverno)
**Kyverno** enforces cryptographic signature verification:
- Policy installed on both clusters blocks any pod whose image lacks a valid Cosign signature.
- Verifies against Sigstore's public Rekor transparency log.
- Development clusters can optionally run in audit mode; production enforces the policy strictly.

---

## 6. Promotion Flow
1. Developer pushes code to `main` in `itayna/java-sample-app`.
2. GHA builds, tests, scans, signs, and pushes image tag `sha-<git-commit-hash>` to GHCR.
3. GHA clones `terasky-platform-ha`, updates `environments/dev/kustomization.yaml`, commits, and pushes.
4. ArgoCD on `kind-dev` detects changes and auto-syncs.
5. To promote to prod, the developer opens a Pull Request in `terasky-platform-ha` merging `environments/dev/kustomization.yaml` changes into `environments/prod/kustomization.yaml`.
6. PR merge triggers ArgoCD reconciliation on `kind-prod`.

---

## 7. Rollback & Progressive Delivery
- **Production Canary Rollout**: Powered by **Argo Rollouts**.
  - Shifts 20% of traffic to the new version.
  - Automatically assesses stability over 2 minutes by polling the application `/actuator/health` endpoint (requires Spring Boot Actuator dependency added to `java-sample-app`).
  - Passes validation → completes rollout to 100%.
  - Fails validation → automatically aborts, points 100% of traffic back to stable pods in seconds.
- **Manual Rollback**: Managed by reverting the image tag commit in Git (retriggering the ArgoCD reconciler) or running `kubectl argo rollouts undo` on the target rollout.

---

## Architecture Decision Records (ADRs)

### ADR-1: Supply-Chain Security Tooling
- **Decision**: Use **Trivy** for vulnerability scanning and SBOM generation, and **Cosign** (keyless mode) for cryptographic image signing.
- **Rejected Alternatives**:
  - *Syft + Grype*: Requires coordinating two separate tools and configs. Trivy matches performance as a unified tool.
  - *Cosign static keypair*: Storing a private key in GitHub Secrets introduces rotation/leak risks. Keyless mode leverages ephemeral OIDC certs tied to the GHA workflow execution.
- **Justification**: Trivy simplifies CI pipeline complexity. Cosign keyless signing removes static key rotation operational overhead.

### ADR-2: GitOps Engine
- **Decision**: Use **ArgoCD** as the GitOps engine.
- **Rejected Alternatives**:
  - *FluxCD*: Great lightweight agent, but lacks a built-in UI by default and has a smaller ecosystem footprint (~60% lower usage based on CNCF survey data).
- **Justification**: ArgoCD's dashboard allows real-time visualization of app sync status, which is major for live interview walkthroughs, and its Application resource model maps directly to multi-cluster topologies.

### ADR-3: Multi-Environment Isolation
- **Decision**: Use **2 separate Kind clusters** (`kind-dev`, `kind-prod`).
- **Rejected Alternatives**:
  - *Single cluster, separate namespaces*: Cheaper local memory footprints, but fails to test real multi-cluster network boundaries, ingress isolation, and RBAC patterns.
- **Justification**: Setting up two separate local clusters accurately mimics production boundaries (e.g. cluster-scoped Bitnami Sealed Secrets keys differ between clusters).

### ADR-4: GitOps Secret Management
- **Decision**: Use **Bitnami Sealed Secrets**.
- **Rejected Alternatives**:
  - *SOPS with age*: Requires installing decryption binaries/plugins inside ArgoCD. Sealed Secrets works natively as an in-cluster CRD parser, meaning ArgoCD remains completely vanilla.
- **Justification**: Less complex cluster configuration. Works out-of-the-box with standard GitOps tools.

### ADR-5: Repository Split Strategy
- **Decision**: Use **public `itayna/java-sample-app` fork + private `terasky-platform-ha` repo**.
- **Rejected Alternatives**:
  - *Detach fork and make private*: Loses the GitHub fork relationship and upstream sync capability.
  - *Keep everything in one private repo*: Violates the assignment requirement to fork the upstream public repo.
- **Justification**: GitHub does not permit private forks of public repositories. This split allows the fork relationship to remain intact for the sample app while keeping all sensitive infrastructure code, secrets (even sealed ones), and architectural documentation private.

---

## Security Considerations

1. **Public Images**: Images stored in GHCR are public, signed with Cosign. Anyone can verify signatures but cannot modify images.
2. **Private GitOps Manifests**: All deployment configurations, secrets (sealed), and cluster topology remain private in `terasky-platform-ha`.
3. **Supply-Chain Verification**: Kyverno blocks unsigned images. Trivy scan breaks build on CRITICAL vulnerabilities.
4. **Credential Isolation**: GitHub Deploy Keys are scoped read-only to `terasky-platform-ha`. CI workflow uses separate PAT with minimal `packages:write` and `contents:write` scopes.

---

## Prerequisites

- Docker Desktop or Docker Engine running
- `kubectl` installed
- `kind` installed
- `helm` installed
- `kubeseal` installed (Sealed Secrets CLI)
- `cosign` v2.6.2+ installed
- GitHub CLI (`gh`) authenticated
- Two GitHub repositories:
  - `itayna/java-sample-app` (public fork, already exists)
  - `terasky-platform-ha` (private, to be created)

---

## Next Steps

1. Add Spring Boot Actuator dependency to `java-sample-app/pom.xml`.
2. Create multi-stage `Dockerfile` in `java-sample-app`.
3. Write GitHub Actions CI workflow `.github/workflows/delivery.yml` in `java-sample-app`.
4. Bootstrap `kind-dev` and `kind-prod` clusters.
5. Install ArgoCD, Sealed Secrets, Kyverno on both clusters.
6. Create ArgoCD Application manifests in `terasky-platform-ha/gitops/argocd-apps/`.
7. Write Kubernetes manifests in `terasky-platform-ha/environments/{dev,prod}/`.
8. Test end-to-end flow: code push → CI → dev deploy → PR → prod canary → rollback.
9. Write runbooks for setup, deployment, and rollback procedures.