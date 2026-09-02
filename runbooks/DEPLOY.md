# DEPLOY — a change from commit to production

Two mechanisms, deliberately different. Dev is automatic because breakage there
is the point; prod is a manual gate because the only automated signal available
is a health check ([ADR-0006](../docs/adr/0006-promotion-flow.md)).

Every command below is per service:

```bash
SERVICE=java-sample-app
```

## Dev — automatic, no human step

A push to `main` in the service repository runs the shared pipeline
(`itayna/platform-workflows`, `@v1`): name guard → `mvn -B verify` (Checkstyle
bound to `validate`, then tests) → Trivy filesystem scan → multi-arch build and
push to GHCR as `:<12-char-sha>` → Trivy image scan → SPDX SBOM attached →
keyless `cosign sign` → a commit of `newTag:` into
`environments/dev/$SERVICE/kustomization.yaml` in this repository.

Argo CD picks that commit up within ~3 minutes.

```bash
gh run watch --repo itayna/$SERVICE          # the pipeline
kubectl config use-context kind-kind-dev
kubectl -n argocd get applications.argoproj.io $SERVICE-dev
kubectl -n default get pods -l app=$SERVICE -w
```

Confirm the cluster is running the tag Git asked for:

```bash
grep newTag environments/dev/$SERVICE/kustomization.yaml
kubectl -n default get pods -l app=$SERVICE \
  -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'
```

Those two agreeing is the whole GitOps claim. They once did not, and nothing
reported it — [ADR-0011](../docs/adr/0011-kyverno-autogen-off.md).

## Prod — the promotion gate

**Never edit `environments/prod/` by hand.** Promotion is the `promote-prod`
workflow in this repository. It re-verifies the image signature — in a
different repository from the one that signed it, so a compromised service
pipeline cannot both mint and approve its own release — and opens a pull
request. Merging that pull request is the deployment.

Hand-editing also breaks the audit trail: `bin/scorecard` derives the
"Promoted via PR" column by matching the prod tag to a
`promote <service>:<tag> to prod` commit in this history. A tag that arrived any
other way is a red row and a failing check, which is the behaviour asked for.

### 1. Dispatch

```bash
# promote whatever dev is running
gh workflow run promote-prod.yml -f service=$SERVICE

# or an explicit tag
gh workflow run promote-prod.yml -f service=$SERVICE -f tag=<12-char-sha>

gh run watch
```

If the signature does not verify against the pipeline's OIDC identity, the run
fails here and no pull request is opened. That is the gate doing its job.

### 2. Review and merge

```bash
gh pr list
gh pr view <N>
gh pr merge <N>          # squash or merge commit; both keep the promote message
```

Worth actually looking at: the diff is one `newTag:` line. If it is more than
that, something else changed in `environments/prod/$SERVICE/`.

### 3. Watch the canary

```bash
kubectl config use-context kind-kind-prod
kubectl argo rollouts get rollout $SERVICE -n default --watch
```

Steps are 20/40/60/80% with a 2-minute pause at each, `maxUnavailable: 0`. With
no traffic router the weight is approximated by replica count, so at three
replicas the honest description is "one canary pod, then two"
([ADR-0003](../docs/adr/0003-argo-rollouts.md)).

A background `AnalysisRun` polls `/actuator/health` on the canary Service every
30s from step 1. Three consecutive non-`UP` readings abort the rollout and scale
the canary back down, with the stable ReplicaSet never having left service.

```bash
kubectl get analysisrun -n default
kubectl describe analysisrun <name> -n default | tail -30
```

The analysis criteria are one `ClusterAnalysisTemplate` in
`environments/prod/_platform/`, referenced with `clusterScope: true`, so no
team owns a copy of the platform's abort conditions.

### 4. Manual canary control

```bash
kubectl argo rollouts promote $SERVICE -n default   # skip remaining steps
kubectl argo rollouts abort   $SERVICE -n default   # stop, keep stable
kubectl argo rollouts retry   $SERVICE -n default   # after a fixed abort
```

`abort` leaves Git ahead of the cluster. Either revert the promotion PR or
re-promote a good tag, or `selfHeal` will re-apply the aborted one —
[ROLLBACK.md](ROLLBACK.md).

## Verify

```bash
curl http://localhost:9080/actuator/health          # prod, via the kind host port
kubectl argo rollouts status $SERVICE -n default
kubectl -n default get pods -l app=$SERVICE \
  -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}'
```

Every image should be the promoted tag at a digest — Kyverno pins each admitted
pod to the digest it verified.

Compliance after the fact:

```bash
bin/scorecard        # writes CATALOG.md, exits non-zero on a red row
```

## Troubleshooting

Stuck syncs, admission denials, `ImagePullBackOff`, a `Pending` analysis run and
the rest are in [RUNBOOK.md](../RUNBOOK.md#debugging-my-deploy-is-stuck) — the
list is ordered by how often each cause actually fires, so work down it rather
than guessing.
