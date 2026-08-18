# ADR-0005: Keyless cosign signing, enforced by Kyverno at admission

- **Status**: Accepted
- **Date**: 2026-08-18

## Context

"Signed images only" is worth nothing if the signature is checked in the same
pipeline that produced it. The check has to happen at the point where the
artefact becomes a running process, and it has to be tied to a specific
producer, not to "someone signed this".

## Decision

`delivery.yml` signs the pushed image with `cosign sign --yes`, using the
workflow's GitHub OIDC token — no signing key exists anywhere. Sigstore records
the signature in the Rekor transparency log.

A Kyverno `ClusterPolicy` (`clusters/policies/verify-image-signatures.yaml`)
matches Pods in `default` with images under
`ghcr.io/itayna/java-sample-app:*` and requires a keyless attestor whose subject
is exactly:

```
https://github.com/itayna/java-sample-app/.github/workflows/delivery.yml@refs/heads/main
```

with issuer `https://token.actions.githubusercontent.com`.
`validationFailureAction: Enforce` and `failurePolicy: Fail`.

## What the signature actually proves

That *this specific workflow file, on `main`, in that repository* produced the
image — because the OIDC subject encodes all four. It does **not** prove the code
is good, that review happened, or that the build was reproducible. A signed
image from the same repo's `feature/x` branch, from a fork, or from a different
workflow in the same repo is rejected, which is the property that makes it
useful: an attacker with registry push rights cannot get a pod scheduled, and an
attacker who can add a workflow to a branch cannot either.

## Consequences

- Nothing runs in `default` on either cluster unless it came from that workflow.
  Deliberately verified during bootstrap: before the first signed image existed,
  the prod Rollout was denied at admission rather than starting an unverified
  pod.
- `failurePolicy: Fail` means a broken Kyverno blocks all pod creation in
  `default`. That is the intended trade (fail closed), and the recovery path is
  in [RUNBOOK.md](../../RUNBOOK.md#kyverno-is-down-and-nothing-can-schedule).
- Verification reaches out to Rekor and GHCR at admission time, so admission
  depends on external availability; the policy sets
  `webhookTimeoutSeconds: 30`.
- The trusted subject is pinned to a branch and a workflow filename. Renaming
  the workflow file or promoting from a release branch requires a policy change —
  friction that is the point, but friction that must be documented.

## Alternatives rejected

**Keyed cosign (`cosign generate-key-pair`).** Works offline, no Rekor
dependency at admission. Rejected because it introduces a long-lived private key
to store, rotate and eventually leak, and the policy could then only assert "a
holder of this key signed it" — not which workflow produced it.

**Notation / Notary v2 with an internal CA.** The right answer for an
organisation that already runs PKI, and it avoids the public transparency log.
Rejected: standing up a CA is more operational surface than this whole platform,
and the ecosystem tooling here (Kyverno's native cosign support, GitHub OIDC)
lines up behind Sigstore.

**OPA Gatekeeper for enforcement.** Comparable maturity as an admission
controller. Rejected because image-signature verification would mean Rego plus an
external data provider to talk to the registry and Rekor, whereas Kyverno has
`verifyImages` as a first-class field and mutates the image reference to a digest
as part of the check — mutation to digest is the part that closes the
tag-reuse hole, and getting that right in Rego is work with no upside here.

**Verify in CI only (`cosign verify` as a pipeline step).** Cheap, no admission
dependency. Rejected because it protects nothing: anything applied to the cluster
by any other path — a human `kubectl`, a stale Argo CD revision, a compromised
registry tag — never passes through that step.
