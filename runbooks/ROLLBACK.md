# Rollback Guide

Manual and automatic rollback procedures.

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
git log --oneline environments/prod/kustomization.yaml
```

Find last working commit, extract image tag:

```bash
git show <commit-sha>:environments/prod/kustomization.yaml | grep newTag
```

Revert prod kustomization:

```bash
GOOD_TAG=<previous-working-tag>
yq eval ".images[0].newTag = \"$GOOD_TAG\"" -i environments/prod/kustomization.yaml
git add environments/prod/kustomization.yaml
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

Same as prod Option 2: revert `environments/dev/kustomization.yaml` to last known good tag.

```bash
cd terasky-platform-ha
GOOD_TAG=<previous-working-tag>
yq eval ".images[0].newTag = \"$GOOD_TAG\"" -i environments/dev/kustomization.yaml
git add environments/dev/kustomization.yaml
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
