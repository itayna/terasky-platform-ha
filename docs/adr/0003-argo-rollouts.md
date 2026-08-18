# ADR-0003: Argo Rollouts for prod progressive delivery

- **Status**: Accepted
- **Date**: 2026-08-18

## Context

Prod needs a deploy that can be aborted automatically on a bad image, and a
rollback measured in seconds rather than in "how fast can someone open a PR".
Dev deliberately stays a plain `Deployment` — it is where breakage is allowed to
be visible.

There is no ingress controller or service mesh in the `kind` clusters
([ADR-0002](0002-kind-two-clusters.md)), so no component can split HTTP traffic
by weight.

## Decision

`environments/prod` deploys a `Rollout` with a canary strategy at 20/40/60/80%,
`maxUnavailable: 0`, plus a background `AnalysisTemplate` that polls
`/actuator/health` on the canary Service every 30s and aborts after three
consecutive non-`UP` readings.

Without a traffic router, Argo Rollouts approximates weight by replica count.
With three replicas the steps round to pod granularity — the honest description
is "one canary pod, then two", not "20% of requests". Stated here so it is not
oversold in a demo.

## Consequences

- A bad image is caught by the analysis run and the canary is scaled back down
  automatically; the stable ReplicaSet never left service.
- `kubectl argo rollouts undo` gives a seconds-scale revert, at the cost of
  diverging from Git until the promotion PR is reverted — see the rollback table
  in [README.md](../../README.md#rollback).
- The abort signal is liveness/readiness-grade, not error-rate-grade. A release
  that returns HTTP 500 on the business endpoint while Actuator still reports
  `UP` will pass the canary. This is the single biggest known gap and is tracked
  in [FUTURE.md](../../FUTURE.md).

## Alternatives rejected

**Flagger.** Equivalent feature set and arguably nicer metric handling.
Rejected because it expects a mesh or ingress provider (Istio, Linkerd, NGINX,
Gateway API) to do the weighting; in a bare `kind` cluster that means installing
a mesh, which the assignment puts explicitly out of scope. Argo Rollouts
degrades gracefully to replica-count canaries without one, and Argo CD already
renders its health status natively.

**Plain `Deployment` with `RollingUpdate` and `maxSurge`.** Zero new CRDs, one
fewer controller to upgrade. Rejected because it has no automated abort: a
rolling update with passing readiness probes will happily replace every pod with
a broken build, and recovery then depends on a human noticing.

**Blue/green.** Cleaner rollback semantics (flip the Service selector back) and
no partial-traffic states. Rejected because it needs double the replicas at the
switch point and gives a binary signal — the whole release is live or it isn't —
so an automated abort has almost no time to act. Canary is the better fit for
"catch it before it is everywhere".
