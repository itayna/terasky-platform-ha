# Rollback Guide

Manual and automatic rollback procedures.

## Speed, trigger, and in-flight traffic

| Tier | Speed | Trigger |
|---|---|---|
| Automatic canary abort | seconds — 3 consecutive non-`UP` `/actuator/health` reads (~90s of polling) | `AnalysisRun` in `_platform`, no human involved |
| Manual `rollouts abort` / `undo` | seconds | operator decision, still-rolling or fully-promoted bad image |
| Revert platform config commit | one Argo CD sync interval (~3 min, or `argocd app sync` to force it) | operator decision |
| Move `v1` back a minor | next push per service | platform-team decision |

**In-flight traffic** during abort or undo: there is no service mesh here (deliberately out of
scope, see README), so canary traffic split is plain Kubernetes `Service` endpoint weighting —
roughly proportional to how many canary vs. stable pods exist, not a real percentage-based split.
On abort, Argo Rollouts removes the canary pods from the `Service`'s endpoints immediately, so no
*new* connections reach them; requests already in flight to a canary pod finish or fail per that
pod's `terminationGracePeriodSeconds` (default 30s) rather than being cut instantly. Nothing is
retried automatically — a request in flight when its pod is torn down surfaces as a client-side
error, which is why the abort condition is 3 consecutive failures rather than 1: it trades a few
more bad requests for not aborting on a single flaky health check.

## Image rollback vs. a database-adjacent change

`rollouts undo` / `git revert` only ever change which **image** runs — they do not, and cannot,
undo a database migration. Treat the two as separate failure classes:

- **Bad image, schema unchanged** — the case this repo automates. Undo/abort is safe and
  sufficient; the previous image is compatible with the current schema by definition.
- **Bad image that shipped a destructive migration** (dropped/renamed a column, backfill that
  overwrote data) — rolling the image back is *not* safe on its own: the old code may now query a
  column that no longer exists, or the schema may be silently wrong for it. This platform has no
  migration tooling yet (no service here owns a database — see FUTURE.md), so the documented
  policy is: only ever ship migrations as expand/contract (add-nullable-column now, backfill,
  switch reads, drop-old-column in a *later* release) so an image rollback is always
  schema-compatible. A genuinely destructive migration is not undone by GitOps at all — it needs a
  restore from backup or a forward-fix release, both slower and riskier than an image rollback, and
  both outside what `kubectl argo rollouts undo` does for you.

Every command below is per service. Set it once:

```bash
SERVICE=java-sample-app
```

## Automatic Rollback (Prod Canary)

Argo Rollouts auto-aborts canary on health check failures.

**Trigger**: 3 consecutive health check failures during canary.

**Behavior**:
1. Rollout aborts immediately
2. All traffic routes back to stable revision
3. Canary pods scale down after 30s
4. Rollout status shows `Degraded`

**Monitor**:

```bash
kubectl config use-context kind-kind-prod
kubectl argo rollouts get rollout java-sample-app --watch
```

**Recovery**:

After fixing root cause, retry rollout:

```bash
kubectl argo rollouts retry java-sample-app
```

Or revert to previous image tag (see Manual Rollback below).

## Manual Rollback (Prod)

### Option 1: Abort Active Rollout

If canary in progress and unhealthy:

```bash
kubectl config use-context kind-kind-prod
kubectl argo rollouts abort java-sample-app
```

Stable revision (previous working version) stays active.

### Option 2: Revert Image Tag

Revert to last known good image:

```bash
cd terasky-platform-ha
git log --oneline environments/prod/$SERVICE/kustomization.yaml
```

Find last working commit, extract image tag:

```bash
git show <commit-sha>:environments/prod/$SERVICE/kustomization.yaml | grep newTag
```

Revert prod kustomization:

```bash
GOOD_TAG=<previous-working-tag>
yq eval ".images[0].newTag = \"$GOOD_TAG\"" -i environments/prod/$SERVICE/kustomization.yaml
git add environments/prod/$SERVICE/kustomization.yaml
git commit -m "rollback prod to $GOOD_TAG"
git push
```

ArgoCD auto-syncs rollback.

Monitor:

```bash
kubectl argo rollouts get rollout java-sample-app --watch
```

### Option 3: Undo Rollout Revision

Use Argo Rollouts native undo:

```bash
# List revisions
kubectl argo rollouts history java-sample-app

# Rollback to previous revision
kubectl argo rollouts undo java-sample-app

# Rollback to specific revision
kubectl argo rollouts undo java-sample-app --to-revision=<N>
```

## Manual Rollback (Dev)

Dev uses standard Deployment (no canary). Rollback via kubectl or git revert.

### kubectl rollback

```bash
kubectl config use-context kind-kind-dev

# Check rollout history
kubectl rollout history deployment/java-sample-app

# Rollback to previous revision
kubectl rollout undo deployment/java-sample-app

# Rollback to specific revision
kubectl rollout undo deployment/java-sample-app --to-revision=<N>
```

### Git revert (recommended)

Same as prod Option 2: revert `environments/dev/$SERVICE/kustomization.yaml` to last known good tag.

```bash
cd terasky-platform-ha
GOOD_TAG=<previous-working-tag>
yq eval ".images[0].newTag = \"$GOOD_TAG\"" -i environments/dev/$SERVICE/kustomization.yaml
git add environments/dev/$SERVICE/kustomization.yaml
git commit -m "rollback dev to $GOOD_TAG"
git push
```

ArgoCD auto-syncs rollback.

## Emergency Rollback (Prod Down)

If prod completely broken and canary stuck:

```bash
kubectl config use-context kind-kind-prod

# Scale down all pods
kubectl scale rollout java-sample-app --replicas=0

# Revert image tag via git (see Option 2)

# Scale back up
kubectl scale rollout java-sample-app --replicas=3

# Monitor
kubectl argo rollouts get rollout java-sample-app --watch
```

## Verification After Rollback

```bash
# Check pod image
kubectl get pods -l app=java-sample-app -o jsonpath='{.items[0].spec.containers[0].image}'

# Check rollout status
kubectl argo rollouts status java-sample-app

# Check app health
curl http://localhost:9080/actuator/health

# Check app endpoints
curl http://localhost:9080
curl http://localhost:9080/welcome
```

## Root Cause Analysis

After rollback, investigate failure:

```bash
# Check previous pod logs
kubectl logs -l app=java-sample-app --previous

# Check events
kubectl get events --sort-by='.lastTimestamp' | grep java-sample-app

# Check rollout events
kubectl describe rollout java-sample-app

# Check analysis run results
kubectl get analysisrun
kubectl describe analysisrun <run-name>
```

## Prevent Future Failures

After identifying root cause:

1. Fix bug in code
2. Add test case covering failure scenario
3. Update health check if needed
4. Test in dev environment first
5. Monitor canary rollout closely in prod

## Rollback Approval

For prod rollbacks:
1. Document incident
2. Notify team
3. Execute rollback
4. Verify stability
5. Post-incident review
