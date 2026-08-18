# RUNBOOK — platform operator

Day-2 procedures for whoever owns this platform. Application-level procedures
(deploy a change, roll one back) live in [runbooks/](runbooks/); this file is
about the platform itself.

Context switching, throughout:

```bash
kubectl config use-context kind-kind-dev    # or kind-kind-prod
```

Every change here is tried on dev first. That is the entire reason there are two
clusters ([ADR-0002](docs/adr/0002-kind-two-clusters.md)).

---

## Debugging "my deploy is stuck"

Work down this list. It is ordered by how often each cause actually fires.

```bash
make status     # sync + health for both environments, plus pods
```

**1. Argo CD has not seen the commit.** Sync interval is ~3 minutes.

```bash
kubectl -n argocd get applications.argoproj.io java-sample-app-dev \
  -o jsonpath='{.status.sync.revision}{"\n"}'
```

If that is not the commit you expect, force a refresh
(`argocd app get java-sample-app-dev --refresh`). If it never advances, the
repository credential is the suspect — check
`kubectl -n argocd logs deploy/argocd-repo-server` for SSH errors and re-run
`make repo-secret DEPLOY_KEY=...`.

**2. Synced, but pods are not there.** Look for admission denial, not for the
pod:

```bash
kubectl get events -n default --sort-by=.lastTimestamp | tail -20
kubectl get rs -n default -o wide
```

`admission webhook "mutate.kyverno.svc-fail" denied the request` means the image
failed signature verification. Confirm from outside the cluster:

```bash
cosign verify ghcr.io/itayna/java-sample-app:<tag> \
  --certificate-identity-regexp="^https://github.com/itayna/java-sample-app/" \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com
```

If `cosign verify` passes but Kyverno denies, the mismatch is in the policy's
pinned subject — a renamed workflow file or a non-`main` branch will do it
([ADR-0005](docs/adr/0005-cosign-keyless-kyverno.md)).

**3. `ImagePullBackOff`.** Either the pull secret or the platform:

```bash
kubectl get secret ghcr-pull-secret -n default            # exists? controller unsealed it?
kubectl logs -n kube-system -l name=sealed-secrets-controller | tail -20
kubectl describe pod <pod> -n default | grep -A5 Events
```

`no matching manifest for linux/arm64` is not a credentials problem — the image
was not built multi-arch. `kind` on Apple Silicon needs `linux/arm64` in the
buildx platform list.

**4. Rollout paused mid-canary (prod).**

```bash
kubectl argo rollouts get rollout java-sample-app -n default
kubectl get analysisrun -n default
kubectl describe analysisrun <name> -n default | tail -30
```

A `Failed` analysis run means the abort already happened and the canary is being
scaled down — that is the system working. A run stuck `Pending` usually means the
canary Service has no endpoints, so the health probe never resolved.

---

## Upgrading Argo CD

Pinned in `clusters/kind-*/bootstrap.sh` as `ARGOCD_VERSION`.

1. Read the upstream release notes for the target version — specifically the CRD
   and `Application` schema changes.
2. Bump `ARGOCD_VERSION` in `clusters/kind-dev/bootstrap.sh`, commit, and re-run
   `make bootstrap-dev`. The install is `kubectl apply` of the upstream manifest,
   so it is an in-place upgrade.
3. Verify before touching prod:
   ```bash
   kubectl -n argocd rollout status deploy/argocd-server
   kubectl -n argocd get applications.argoproj.io      # both apps still Synced/Healthy
   ```
   Then make a trivial commit to `environments/dev` and confirm it still
   reconciles. An upgrade that leaves the UI up but reconciliation broken is the
   failure mode worth catching.
4. Repeat for `clusters/kind-prod/bootstrap.sh`.

Rollback: re-apply the previous version's manifest. CRD schema changes are the
exception — those do not cleanly reverse, which is why dev goes first.

## Upgrading Kyverno

Pinned as `KYVERNO_CHART_VERSION` (Helm chart version, **not** the app version —
chart `3.8.2` ships Kyverno `v1.18.2`; the two numbering schemes have already
caused one failed bootstrap).

Kyverno runs with `failurePolicy: Fail`, so a bad upgrade blocks pod creation in
`default`. On dev:

```bash
helm upgrade --install kyverno kyverno/kyverno -n kyverno --version <new> --wait
kubectl -n kyverno rollout status deploy/kyverno-admission-controller
kubectl get clusterpolicy verify-image-signatures -o jsonpath='{.status.ready}{"\n"}'
```

Then delete one app pod and confirm its replacement is admitted. If the policy
schema changed, `spec.validationFailureAction` and the `verifyImages` block are
the fields that move between Kyverno majors — check both.

## Kyverno is down and nothing can schedule

Symptom: every pod creation in `default` fails with a webhook error, including
Argo CD's own retries.

```bash
kubectl -n kyverno get pods
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations | grep kyverno
```

If the controller cannot be restored quickly, the break-glass is to delete the
webhook configurations — admission stops being enforced and workloads schedule
again:

```bash
kubectl delete mutatingwebhookconfiguration kyverno-resource-mutating-webhook-cfg
kubectl delete validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg
```

**This disables signature enforcement cluster-wide.** It is an incident action,
not a fix: unsigned images can run until Kyverno is healthy and the webhooks are
recreated (the controller recreates them on start). Record it, and re-verify
enforcement afterwards by attempting to run an unsigned image and confirming the
denial.

## Rotating the CI deploy key

The app repository's CI pushes to this repository with an SSH deploy key
(`PLATFORM_REPO_DEPLOY_KEY` secret in `itayna/java-sample-app`). Argo CD reads
this repository with a key of its own.

```bash
ssh-keygen -t ed25519 -N '' -f /tmp/platform_deploy -C "delivery-bot"
gh repo deploy-key add /tmp/platform_deploy.pub \
  --repo itayna/terasky-platform-ha --title delivery-bot --allow-write
gh secret set PLATFORM_REPO_DEPLOY_KEY --repo itayna/java-sample-app \
  < /tmp/platform_deploy
make repo-secret DEPLOY_KEY=/tmp/platform_deploy   # if reusing for Argo CD read access
gh repo deploy-key delete <old-key-id> --repo itayna/terasky-platform-ha
rm /tmp/platform_deploy*
```

Verify by triggering a build and confirming the dev tag commit still lands.

## Backing up the sealed-secrets key

Each cluster's controller holds the private key that decrypts every
`SealedSecret` committed for it. Lose it and the committed secrets are
unrecoverable — they must be re-sealed from the original plaintext.

```bash
kubectl -n kube-system get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key.yaml
```

That file is a plaintext private key. It does not go in Git, in a ticket, or in
this repository. Store it wherever the organisation keeps root credentials; for
this local setup, losing it just means re-running `kubeseal`.

Restore into a rebuilt cluster:

```bash
kubectl apply -f sealed-secrets-key.yaml
kubectl -n kube-system delete pod -l name=sealed-secrets-controller
```

---

## The platform bar, and falling off it

A service is on the paved road when all of the following hold. This is the list a
compliance check should assert, and today only the first three are enforced by
machinery rather than by review:

| # | Requirement | Enforced by |
|---|---|---|
| 1 | Image signed by the service's own delivery workflow on `main` | Kyverno, at admission (**hard**) |
| 2 | No CRITICAL CVEs in source or image | Trivy gates in CI (**hard**) |
| 3 | Deployed only via Argo CD from this repository | `selfHeal` reverts anything else (**hard**) |
| 4 | SBOM published for every image | CI step exists; nothing verifies it later |
| 5 | Health endpoints wired to probes and to canary analysis | convention |
| 6 | Prod changes arrive as promotion PRs | convention |

**A service falls off the road** in one of two ways:

- *Loudly* — it stops satisfying 1–3. It cannot deploy. Nothing to decide; fix
  the pipeline.
- *Quietly* — it stops satisfying 4–6: someone adds a second workflow that
  builds images, pins prod by editing `environments/prod` directly, or drops the
  Actuator dependency so the canary analysis passes vacuously. Nothing breaks.
  This is the dangerous case, and today it is caught only by a human reading a
  diff. Closing that gap is the top Stage 2 item in [FUTURE.md](FUTURE.md).

**Rejoining** means, in order: restore the delivery workflow from the template
(so the trusted OIDC subject matches the policy again), confirm the Trivy gates
run and pass, and delete any manifests applied outside Argo CD so the next sync
is a no-op rather than a fight with `selfHeal`. Verify by deploying one
deliberate no-op change end to end.

## Emergency: a bad image is in prod

1. Abort or undo first — do not start with Git.
   ```bash
   kubectl argo rollouts abort java-sample-app -n default   # still rolling
   kubectl argo rollouts undo  java-sample-app -n default   # already at 100%
   ```
2. Then make Git agree, or `selfHeal` will re-apply the bad tag: revert the
   promotion PR in this repository.
3. Confirm: `kubectl argo rollouts get rollout java-sample-app -n default` and
   `make status`.

Details, timings and the database-adjacent variant:
[runbooks/ROLLBACK.md](runbooks/ROLLBACK.md).
