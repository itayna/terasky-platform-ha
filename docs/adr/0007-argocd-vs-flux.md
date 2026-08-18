# ADR-0007: Argo CD as the reconciler, not Flux

- **Status**: Accepted
- **Date**: 2026-08-17

## Context

Cluster state must be driven from Git by a reconciler. Both Argo CD and Flux are
CNCF-graduated, actively maintained, and would satisfy the requirement. The
choice has to be defended on operator experience, not on features neither
project lacks.

## Decision

Argo CD (v2.12.3), one instance per cluster, with `Application` resources per
environment and `syncPolicy.automated` (`prune: true`, `selfHeal: true`).

## Rationale

- **The 3 AM property.** Argo CD ships a UI that shows the live resource tree,
  the diff between Git and cluster, and per-resource health in one place. With
  Flux the same answers come from `flux get`/`kubectl describe` across several
  CRDs. Both work; one is faster to hand to someone who is not the person who
  built the platform, which matters for a paved road other teams use.
- **`selfHeal` makes drift a demonstrable behaviour.** A manual `kubectl edit`
  is reverted, and the UI shows it happening — a concrete answer to the drift
  question rather than an assertion.
- **Argo Rollouts integration.** Prod uses `Rollout` objects
  ([ADR-0003](0003-argo-rollouts.md)); Argo CD understands their health natively,
  so a paused or degraded canary surfaces as application health rather than as
  an unknown CRD.
- **Sync waves and app-of-apps** give Stage 2 an obvious growth path for
  onboarding service #2 without inventing structure.

## Consequences

- Argo CD is a heavier component than Flux's controller set: more moving parts
  per cluster, and two instances to upgrade in lockstep with these manifests.
  Upgrade procedure is in [RUNBOOK.md](../../RUNBOOK.md#upgrading-argo-cd).
- The UI is an additional attack surface and another credential to manage; it is
  reachable only via `kubectl port-forward` here, and the initial admin secret
  should be rotated before this is anything other than a local demo.
- Repository access is via an SSH deploy key held in each cluster
  ([ADR-0001](0001-two-repositories.md)), so Argo CD compromise yields read
  access to platform state.

## Alternatives rejected

**Flux.** Lighter, composes cleanly from small controllers, and its
`Kustomization`/`HelmRelease` split is arguably a better fit for pure
infrastructure. Rejected mainly on the operator-visibility argument above, and
because Flux's image-automation controllers invite registry-triggered deploys,
which this design deliberately avoids ([ADR-0006](0006-promotion-flow.md)). If
this platform grew to many clusters with no humans looking at a UI, that
trade-off flips — noted in [FUTURE.md](../../FUTURE.md).

**A CI job running `kubectl apply` / `kustomize build | kubectl apply`.**
Trivial to build and debug, no new components. Rejected because it is push-based
with no continuous reconciliation: drift is never corrected, cluster credentials
have to live in CI, and there is no answer to "is the cluster currently what Git
says". The assignment also flags manual apply as a hard interview topic — for
good reason.
