# ADR-0004: sealed-secrets for the GHCR pull credential

- **Status**: Accepted
- **Date**: 2026-08-17

## Context

Pulling `ghcr.io/itayna/java-sample-app` needs a registry credential in each
cluster. Argo CD is the only deploy path, so the credential must be reachable
from Git, and plaintext secrets in Git are never acceptable. There is no cloud
secret manager available at zero cost with no payment method.

## Decision

Bitnami sealed-secrets. The controller in each cluster holds a private key; the
credential is sealed with that cluster's public key via `kubeseal` and the
resulting `SealedSecret` is committed to `environments/<env>/`. The controller
decrypts it into a normal `Secret` in the target namespace.

## Consequences

- The committed artefact is useless to anyone without the target cluster's
  controller key, including anyone who clones this repository — which is public.
- A `SealedSecret` sealed for dev cannot decrypt in prod. Cross-environment copy
  paste fails loudly instead of silently sharing a credential.
- Cost: the controller's key is now cluster state that must be backed up, or a
  rebuilt cluster cannot read its own committed secrets and every secret has to
  be re-sealed. That step is in [RUNBOOK.md](../../RUNBOOK.md).
- Rotation is a `kubeseal` run plus a commit — no in-cluster edit, so the
  rotation is auditable.

## Alternatives rejected

**SOPS + age.** Excellent for multi-environment config, and encrypts values
in-place so diffs stay readable field by field. Rejected because decryption needs
the age private key wherever the manifests are rendered — for GitOps that means
handing Argo CD (or a plugin/kustomize exec) the key, which widens what a
compromised Argo CD yields. sealed-secrets keeps decryption in a single-purpose
controller whose only job is that one operation.

**External Secrets Operator.** The right answer with a real secret manager
behind it, and the direction to move in
([FUTURE.md](../../FUTURE.md)). Rejected here because every backend worth using
(AWS/GCP/Azure secret managers, Vault as a service) requires either a payment
method or an extra self-hosted stateful component to operate, and the assignment
is capped at zero cost.

**Argo CD-managed credential created out of band.** Fastest, and how the repo
credential itself is handled (`make repo-secret`). Rejected for the pull secret
because it makes cluster state that no commit describes — precisely the drift
that GitOps is supposed to eliminate.
