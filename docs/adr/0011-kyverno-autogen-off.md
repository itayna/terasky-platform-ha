# ADR-0011: Verify Pods only — Kyverno autogen off, no `ignoreDifferences`

- **Status**: Accepted
- **Date**: 2026-08-20

## Context

The signature policy ([ADR-0005](0005-cosign-keyless-kyverno.md)) matches `kind: Pod`.
Kyverno's *autogen* feature silently expands such a policy: it generates parallel rules
for Deployment, StatefulSet, DaemonSet, Job and CronJob so a violation is rejected when
the controller is applied rather than when its pods fail to appear.

`verifyImages` also defaults to `mutateDigest: true`, rewriting a verified
`image:tag` to `image:tag@sha256:...`. Combined with autogen, that rewrite lands on the
**controller's pod template**, so the dev `Deployment` in the cluster permanently
differed from the same Deployment in Git.

Argo CD reported the app `OutOfSync` forever and `selfHeal` re-applied the plain tag on
every sync, which Kyverno immediately re-mutated. The fix applied at the time was an
`ignoreDifferences` entry on `/spec/template/spec/containers/0/image` in the dev
Application.

That worked, and it broke automated dev promotion without a single error anywhere.
`ignoreDifferences` removes the field from Argo CD's diff, and an app whose only change
is an ignored field never becomes `OutOfSync` — so automated sync never fires. The
delivery pipeline kept committing `newTag:` bumps, Argo CD kept reporting `Synced` and
`Healthy`, and the dev cluster kept running the image it had. It sat on
`bc35f2ec0a3b` through three subsequent releases. Nothing failed; the deploy just
stopped happening.

The prod `Rollout` never had the problem. It is a CRD, autogen does not cover it, so
Kyverno mutates only the pods it creates and the Rollout spec in the cluster still
matches Git. Prod needed no `ignoreDifferences` and promoted correctly the whole time.

## Decision

Annotate the policy `pod-policies.kyverno.io/autogen-controllers: none` and delete
`ignoreDifferences` from the dev Application and from `templates/service-v1`.

The policy now verifies pods, and only pods — exactly the shape that already worked for
prod. Controller specs are never rewritten, so what Argo CD renders from Git is what the
cluster holds, and a `newTag:` bump is once again a real diff that automated sync acts
on.

## Rationale

- **It restores the property the platform is built on.** A tag committed to this
  repository must reach the cluster with nobody watching. Anything that makes Argo CD
  report `Synced` while the cluster runs something else is worse than an outage,
  because an outage is visible.
- **Nothing is given up at admission.** Pods are still signature-verified against the
  pipeline's OIDC identity, and `mutateDigest` still pins each admitted pod to the
  digest that was verified — closing the window where a tag is re-pushed between
  verification and pull. Both properties live where they are enforced: on the pod.
- **It removes a special case instead of adding one.** Dev and prod are now governed
  identically. Previously the two environments disagreed about what Argo CD was allowed
  to see, which is why the failure appeared in one and not the other.
- **`ignoreDifferences` is the wrong instrument for a mutating webhook.** It is scoped
  to a field, not to a writer, so it cannot distinguish "Kyverno appended a digest" from
  "the pipeline shipped a new version". Any use of it on a field that GitOps also
  controls has this failure mode.

## Consequences

- A Deployment referencing an unsigned image is now admitted; its **pods** are rejected.
  The failure surfaces as a rollout that never progresses, with the policy message on
  the ReplicaSet's events, rather than as a rejected `kubectl apply`. This is already
  how prod behaves, and Argo CD marks the app `Progressing` then `Degraded`.
- Feedback moves later — the pipeline pushes, Argo CD syncs, and only then do pods fail.
  Signing happens in the same pipeline that deploys, so an unsigned image reaching a
  cluster means the pipeline was bypassed, which is the case this policy exists to stop.
- The policy is applied by `clusters/kind-*/bootstrap.sh`, not by Argo CD, so this
  change reached the clusters through `kubectl apply` rather than a sync. Moving the
  policy under GitOps management is tracked in [FUTURE.md](../../FUTURE.md).

## Alternatives rejected

**`mutateDigest: false` and keep autogen.** Also removes the drift, and keeps rejection
at Deployment-apply time. Rejected because it drops digest pinning for every pod in both
clusters to fix a diff problem in one manifest — trading a real supply-chain property
for a cosmetic one. It also needs `verifyDigest: false` alongside it, or Kyverno rejects
every plain-tag image outright.

**Keep `ignoreDifferences` and add `RespectIgnoreDifferences=false`.** Does not help.
That option controls what a sync *applies*; the bug is that no sync is ever *triggered*,
because the ignored field is the only thing that changed.

**Keep `ignoreDifferences` and drive dev from a digest written by the pipeline.** Have
the pipeline commit `newName@sha256:...` so Git and the mutated cluster spec agree.
Rejected as a larger change to the pipeline, this repository's manifests and the
promotion workflow, to preserve an autogen behaviour that prod never used.

**Scope `ignoreDifferences` with `managedFieldsManagers`.** Ignores only fields written
by a named field manager, which is the precise shape of the problem. Rejected because
admission-webhook mutations are not attributed to a distinct manager reliably enough to
depend on, and a rule that silently stops matching reintroduces exactly this bug.
