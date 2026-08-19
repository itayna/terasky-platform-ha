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

A service is on the paved road when all of the following hold. `bin/scorecard`
asserts every row per service, daily and on every push to `main`, and exits
non-zero if any is red:

| # | Requirement | Enforced by | Scorecard column |
|---|---|---|---|
| 1 | Image signed by the platform pipeline | Kyverno, at admission (**hard**) | Signed |
| 2 | No CRITICAL CVEs in source or image | Trivy gates in CI (**hard**) | Pipeline (a service on `@v1` has them) |
| 3 | Deployed only via Argo CD from this repository | `selfHeal` reverts anything else (**hard**) | GitOps |
| 4 | SBOM published for every image | CI step, verified after the fact | SBOM |
| 5 | Health endpoints wired to probes and to canary analysis | scorecard greps the manifests | GitOps |
| 6 | Prod changes arrive as promotion PRs | scorecard matches the tag to a promotion commit | Promoted via PR |
| 7 | An owner of record | `CODEOWNERS` in the service repository | Owner |

**A service falls off the road** in one of two ways:

- *Loudly* — it stops satisfying 1–3. It cannot deploy. Nothing to decide; fix
  the pipeline.
- *Quietly* — it stops satisfying 4–7: someone adds a second workflow that builds
  images, pins prod by editing `environments/prod` directly, or drops the Actuator
  dependency so the canary analysis passes vacuously. Nothing breaks at deploy
  time. This is the case the scorecard exists for: the quiet failure becomes a red
  row and a failing check within a day.

**Rejoining** means, in order: restore the three-line `delivery.yml` from
`templates/service-v1/repo/` (so the trusted OIDC subject matches the policy
again), confirm the Trivy gates run and pass, and delete any manifests applied
outside Argo CD so the next sync is a no-op rather than a fight with `selfHeal`.
Verify by deploying one deliberate no-op change end to end.

## A red row in CATALOG.md

`bin/scorecard` locally reproduces exactly what the workflow asserts (without
`cosign` installed it renders the two registry columns `⚠️` rather than passing
them):

```bash
bin/scorecard            # writes CATALOG.md, exits 1 on any red row
```

| Column | Red means | Fix |
|---|---|---|
| Owner `❌ none` | no `CODEOWNERS` in the service repository | add `* @handle`; it is the ownership of record, not decoration |
| Pipeline `❌ own copy` | the service has its own copy of the pipeline, so platform-mandated steps never reach it | replace `.github/workflows/delivery.yml` with the template stub |
| Pipeline `⚠️ v1.0` | deliberately pinned behind the floating tag | fine short-term; the warning is the point — move it to `@v1` when the team can |
| Signed `❌` | `cosign verify` failed for the dev tag against the pipeline identity | the image was built by something else. Check the run that produced it; re-push to rebuild through the pipeline |
| SBOM `❌` | no SPDX document attached to that tag | usually the same cause as Signed; an image predating the SBOM step also fails and should be rebuilt |
| GitOps `❌` | a missing child `Application`, `selfHeal` off, no `readinessProbe`, or the Rollout does not reference `health-check` | compare against `templates/service-v1/`; all four are rendered correctly by `platformctl` |
| Promoted via PR `❌` | the prod tag has no `promote <service>:<tag> to prod` commit in this history | someone edited `environments/prod` by hand. Roll it back and re-promote through `promote-prod`, or the audit trail is a lie |

A red row fails the check but changes nothing in a cluster. It is a signal, never
an enforcement action — enforcement lives at admission.

## Shipping a pipeline change to every service

The pipeline is one reusable workflow in `itayna/platform-workflows`; services
reference `@v1` ([ADR-0010](docs/adr/0010-pipeline-version-tags.md)).

1. Commit the change on `main` there and test it against one service by
   temporarily pointing that service's `uses:` at `@main`.
2. Release it:
   ```bash
   git tag v1.1 && git push origin v1.1     # immutable release
   git tag -f v1 v1.1 && git push -f origin v1   # floating tag every service tracks
   ```
3. Every service picks it up on its next push. No service repository changes.
4. Confirm adoption in `CATALOG.md` — the Pipeline column shows what each service
   pins.

**Rolling back a bad release** is moving the floating tag back, because `v1.x` is
immutable:

```bash
git tag -f v1 v1.0 && git push -f origin v1
```

In-flight runs already resolved the old ref and are unaffected; the next push per
service uses `v1.0` again. A service that cannot wait pins `@v1.0` itself, which
shows up as `⚠️ v1.0` in the catalog rather than as a private arrangement.

Note the force-push against a shared ref. It is the documented mechanism, not an
accident, and it is why `v1.x` tags are never moved.

## Onboarding failed halfway

`bin/platformctl new <service>` does four things that can fail independently: it
renders manifests into the working tree, creates the service repository, appends
the catalog, and opens a pull request. It is not transactional — it refuses to
start rather than trying to unwind.

| Symptom | Cause | Recovery |
|---|---|---|
| `error: <name> is already in the catalog` | re-running for a live service | intentional. Re-onboarding is a manifest edit, not a scaffold |
| `gh: Name already exists on this account` | the service repository exists | `platformctl new <svc> --no-repo` to generate manifests only, or pick another name |
| Branch and files exist, no PR | `gh pr create` failed (auth, or `main` moved) | the working tree is correct — push the branch and open the PR by hand |
| PR merged, no pods in dev | the service has no image yet | expected: `newTag: awaiting-first-promotion`. The first push to the service repo produces the first image |
| PR merged, Application missing in Argo CD | root app not registered on that cluster | `make apps` (once per cluster, ever), then `make status` |
| Pods `ImagePullBackOff` | the shared GHCR pull secret is missing or sealed for the other cluster | `kubectl -n default get secret ghcr-pull`; reseal `environments/<env>/_platform/` for that cluster |
| Pods denied at admission | the image is not signed by the pipeline identity | the service is probably still on a copied workflow — see the Pipeline column above |

Dry-run first when in doubt: `bin/platformctl new <svc> --dry-run` renders the
full tree into a scratch copy and prints it, touching nothing.

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
