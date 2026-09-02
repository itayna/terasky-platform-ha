# AI_LOG

How AI was used to build this platform, what it got wrong, and what I overrode.
Written as a working log rather than a testimonial: the useful signal is where the
model's first answer was wrong and how that was caught.

Tooling: Claude Code (Sonnet/Opus) in an agentic loop with shell access, driving
`kubectl`, `kind`, `gh` and `cosign` against two live clusters. Every claim below
is checkable against `git log` in this repository, `itayna/java-sample-app` and
`itayna/platform-workflows`.

## Division of labour

| Work | How it was produced |
|---|---|
| Cluster bootstrap, manifests, workflows, `platformctl`, `scorecard` | AI-drafted, then run against real clusters; every bug below was found by running it |
| ADRs, RUNBOOK, README, this file | AI-drafted from decisions I had already made; reasoning and rejected alternatives reviewed line by line, several rewritten |
| Every design decision that has an ADR | Mine. The model argued alternatives on request, which is what it is good for |
| Verification | Mine, always: `kubectl`, the Argo CD UI, `cosign verify`, a real canary |

The pattern that worked: let it write the thing, then make it prove the thing.
Nothing in this repository was accepted because it looked right.

## Where the first answer was wrong

**`ignoreDifferences` on the prod Rollout froze promotions.** The dev Application
needs `ignoreDifferences` on the container image: Kyverno's `verifyImages` rewrites
the tag to `tag@sha256:...` on admission, so live never matches Git and `selfHeal`
fights the mutation forever. The model applied the same block to the prod
Application by symmetry. Consequence: the prod Rollout's image field was ignored,
so a merged promotion changed Git and nothing in the cluster — the promotion
pipeline appeared to work and did nothing. Found by promoting a tag and watching
the Rollout stay on the old image. Root cause is that Kyverno's autogen covers
Deployment/DaemonSet/StatefulSet/CronJob, not the Rollout CRD, so nothing mutates
that field and there is nothing to ignore. Fix in commit *"Fix prod ArgoCD app:
stop ignoring Rollout image field"*; both Applications now carry a comment
explaining why they differ, because the asymmetry looks like a mistake.

**Argo CD repository access over HTTPS.** First draft gave Argo CD an HTTPS URL
with a token. It failed to authenticate against the private repository, and the
token would have been a second credential to rotate. Switched to an SSH deploy key
per cluster (commit *"switch argocd repo access to ssh deploy key"*, now
[ADR-0001](docs/adr/0001-two-repositories.md)); the same key type is what the
pipeline uses to commit dev tags.

**`:latest` in the image field, denied at admission.** The initial Deployment used
`ghcr.io/itayna/java-sample-app:latest` and Kyverno refused the Pod — correctly, as
a floating tag cannot be verified to a signature. The template still carries
`:latest` as the literal value because kustomize's `images:` transformer replaces
it with the promoted tag; the placeholder is inert. Kept as-is after checking the
rendered output, not the source.

**A Kyverno chart version that does not exist.** Confidently pinned; `helm upgrade`
disagreed. Corrected to 3.8.2 by asking the repository. Cheap failure, and the
reason every version in `clusters/*/bootstrap.sh` is pinned to something that was
actually installed.

**Signing identity under a reusable workflow.** When the pipeline moved into
`itayna/platform-workflows`, the model kept the Kyverno policy trusting each
service's own `delivery.yml` identity. That is wrong: with `workflow_call` the
Fulcio certificate carries the *called* workflow's ref, so no service's image would
have admitted. Caught by reading the certificate identity in the signature rather
than assuming. The trade-off this forces — signatures now prove "built by pipeline
v1.x", not "built by this service's workflow" — is the substance of
[ADR-0008](docs/adr/0008-reusable-workflow-central-pipeline.md), and it is why
onboarding needs no policy edit.

**A scorecard that silently reported nothing.** Two bugs in one script, both from
`set -euo pipefail` interacting with shell semantics the model got wrong. First,
`FAILED=1` was set inside `mark()`, called in a command substitution — a subshell —
so every failure was discarded. Second, with `pipefail`, `x="$(gh api ... | sed ...)"`
aborts the whole script when `gh` 404s, which it does for any repository without a
`CODEOWNERS` file. Both found by running it and getting an empty table with exit 1.
The first run then honestly reported two red rows I had not yet fixed, which is the
behaviour I wanted from it.

**`awk '/^ +repo:/'` matches nothing in BSD awk.** macOS `awk` needed
`[[:space:]]+`. Trivial, but it is the class of bug that makes a scorecard quietly
report zero services, and it argues for running platform tooling in CI where the
runner is known.

**`gh repo create --template ... -- <path>`.** Invented flag syntax. Corrected to
`cd` into a scratch directory and let `gh` clone into `./<service>` — and later
removed entirely, see the next entry.

**Onboarding's first CI run built the wrong service's image.** Every service
scaffolded from the reference app had exactly one failed run at the top of its
history, before the run for its own onboarding commit. The model had read this as
the deploy-key race it had just fixed. It is a second, independent bug:
`gh repo create --template` publishes the template's *initial commit* the instant
the repository exists, and that commit carries `java-sample-app`'s own
`delivery.yml`. GitHub queued a delivery run for it before `platformctl` could
render this service's copy, so the run built and would have signed
`ghcr.io/itayna/java-sample-app` under the new repository's SHA — and `promote-dev`
would then have retagged `java-sample-app` in dev from an unrelated repository's
source. It only ever failed because GHCR denied the cross-package write:

```
#23 ERROR: failed to push ghcr.io/itayna/java-sample-app:a884253c41f9:
denied: permission_denied: write_package
```

Diagnosed from the run log plus `gh api repos/itayna/inventory-service/commits`,
which shows `Initial commit` two seconds ahead of the onboarding commit, each with
its own run. Both `notifications-service` and `inventory-service` show the identical
pair, which is what separated a systemic scaffold defect from one-off noise.

My own first fix was wrong too, and worth recording: disable Actions on the new
repository immediately after creating it, then re-enable after rendering. That
loses the race by construction — the run is already queued when `gh repo create`
returns. The fix is to stop creating a repository that has content before we
control it: clone the reference app locally, render `delivery.yml`, commit, *then*
create the remote and push, so the first commit `main` ever sees already names the
right service. Belt and braces on the platform side, because a copied
`delivery.yml` can reintroduce this by hand: the shared pipeline (v1.4) now refuses
a `service-name` that is not the calling repository's name, before anything builds.

**Lint was missing and nobody noticed.** The pipeline ran `mvn -B verify` and the
README described a build-and-test gate, so "lint" read as covered. It was not: the
reference `pom.xml` had no static-analysis plugin at all, which `mvn -B verify`
happily reports as success. Added Checkstyle bound to `validate`, and verified the
gate the only way that means anything — added an unused import, watched the build
fail with `UnusedImports`, reverted it, watched it pass. The model's first ruleset
was `google_checks.xml`, which fails this repository's existing code on hundreds of
formatting violations; a gate the first team to hit it turns off is worse than no
gate, so the rules are defect-only.

The gate then broke the image build, which is the more interesting half. `mvn -B
verify` passed in CI and the Docker build failed on the next line:
`Unable to find configuration file at location: checkstyle.xml`. The Dockerfile
copies `pom.xml` and `src/`, nothing else, and the in-image `mvn package` runs
`validate` — so it executed the new gate without its ruleset. Neither the model nor
I predicted it; the first live run did. Fixed by copying `checkstyle.xml` into the
build stage, verified by adding an unused import and watching `docker build` fail
with `UnusedImports`. Two things worth recording: the same defect was live in both
services scaffolded from the reference app, so it was fixed in all three rather than
in the one whose run I happened to read; and a gate that only runs outside the
container is a gate that a `docker build` on a laptop skips silently.

**A negative test that passed for the wrong reason.** Checking that admission really
denies unsigned images, the obvious move — `kubectl run` a public `nginx` image — is
worthless: the policy's `imageReferences` is `ghcr.io/itayna/*`, so nginx is out of
scope and admitting it is correct behaviour. The pod was created and for a moment
that read as "enforcement is off". The real evidence was already in the cluster:
every never-promoted prod service is `Degraded` because Kyverno denies its Pod with
`failed to verify image ghcr.io/itayna/<svc>:awaiting-first-promotion ...
MANIFEST_UNKNOWN` — the policy failing closed on an image it cannot verify. Recorded
because a negative test that passes for the wrong reason is worse than no test.

## Where I overrode a working answer

**Onboarding required `kubeseal` and cluster access.** The model's scaffold sealed a
GHCR pull secret per service, per cluster — faithful to the existing layout, and it
worked. I rejected it: a sealed secret is encrypted to one cluster's key, so
onboarding would need cluster credentials, which means a product team cannot onboard
without the platform team. The pull secret moved to
`environments/<env>/_platform/`, shared by every service, and onboarding became a
pull request with no cluster access at all. This is the single change that makes the
"zero platform-team steps" claim true.

**The canary analysis was copied per service.** Each generated service got its own
namespaced `AnalysisTemplate` named `health-check`. Two services in the `default`
namespace would collide, and more importantly each team would own a copy of the
platform's abort criteria and could weaken it. Promoted to a
`ClusterAnalysisTemplate` in `_platform`, referenced with `clusterScope: true`.

**`make apps` per service.** The first scaffold design registered new Argo CD
Applications by running `kubectl apply`. That is a platform-team step per
onboarding, and it creates state no reconciler owns. Replaced with app-of-apps root
Applications over `gitops/argocd-apps/<env>/`, so adding a child Application file
*is* the registration and `make apps` is now once per cluster, ever.

**A catalog that duplicated ownership.** The proposed `catalog/services.yaml` held
owner, pipeline version and manifest paths. Every one of those is a copy of a fact
that lives somewhere else and will drift; a catalog listing an owner who left is
worse than no catalog. Reduced to identity, with `bin/scorecard` deriving the rest
from `CODEOWNERS`, the service's `delivery.yml`, the registry and git history.

**Multi-arch builds.** `linux/amd64,linux/arm64` under QEMU roughly triples build
time for a service nobody runs on arm64 today. Kept anyway — the clusters run on
Apple silicon and a single-arch image fails to pull there. Deliberate cost,
recorded here so it is not mistaken for thoroughness.

**Prose that oversold.** Recurring edit across README, RUNBOOK and the ADRs:
drafts described intent as if it were verified ("ensures", "guarantees"). Anything
not demonstrated was either demonstrated or downgraded to what it is. The scorecard
exists partly because I did not want to be the mechanism keeping those claims true.

## Review pass after the timebox (2026-09-02)

Asked a model to audit the three repositories against the assignment PDF as a
reviewer would: every must/should, every deliverable, every command in the docs
run or resolved against the files. The clusters had been deleted by then, so
nothing live could be checked — which turned out to be the point.

**What it found that I had missed.** `runbooks/SETUP.md` and
`runbooks/DEPLOY.md` were Stage 1 documents that the Stage 2 restructure had
silently orphaned: SETUP applied `gitops/argocd-apps/dev-app.yaml`, a file that
no longer existed, sealed the pull secret to the old path, and omitted
`make repo-secret` — a reviewer following it would have got an Argo CD that
could not read the repository. DEPLOY told the operator to hand-edit
`environments/prod/` with a commit message `bin/scorecard` does not match, so a
promotion done by following my own runbook was a red row in my own catalog; the
local branch I had left behind from a rollback test was literally that
procedure. Both bootstrap scripts printed an Argo CD port-forward on the host
ports `kind-config.yaml` already publishes, so the first command of the demo
would have failed with `address already in use`. And the assignment's
template-versioning question (v1 → v2) had no ADR, no FUTURE entry, nothing —
ADR-0010 covers the pipeline and I had read that as covering the templates.

**What I kept.** Rewritten SETUP and DEPLOY, reviewed line by line against the
Makefile and the workflows; ADR-0012, whose argument — that copies are the right
shape for desired state precisely because the floating tag is the right shape
for CI — I agree with and would have written more weakly; a README for the
reference app, which every scaffolded service inherits and which had still been
the upstream three-liner; a `.gitignore` for the sealed-secrets key backup the
RUNBOOK tells you to create. The stale Stage 1 design spec under
`docs/superpowers/` was deleted: it contradicted ADR-0008 and the README, and I
had already removed one duplicate architecture document for exactly that reason.

**What was wrong in its output.** It dated ADR-0012 `2026-08-21` — inside the
timebox, which is not when it was written. Corrected to the real date; a commit
date that contradicts the document is worse than a document that admits the gap
was found in review. It also asserted, in the reference app's README, that
removing the Tomcat pin "fails the pipeline's Trivy gate" — true when the pin
was added, unverified today, and softened to what is known. And its edit to the
two bootstrap scripts' port hints went through a mounted filesystem that drops
the executable bit, so the commit silently carried `mode 100755 => 100644` and
`make bootstrap` failed with `Permission denied` on the next run — its own
"only echo lines changed" check compared content, not mode. Caught by running
the bootstrap, which is the check that matters.

**What I rejected or deferred.** Removing the Kyverno policy's migration
attestor, which ADR-0008 says to delete once no pre-v1 image is a rollback
candidate. The model was right that it widens what admission trusts. But the
previous prod tag, `bc35f2ec0a3b`, is pre-v1 and is exactly what reverting the
current promotion PR would deploy; deleting the attestor now would turn the
documented rollback into an admission denial. It goes after the next promotion,
when the rollback target is v1-signed. And a real test for the reference app —
the suite was one `contextLoads()`, which I had verified the lint gate around and
never the test gate — was held back until `mvn -B verify` had run on it locally,
because the model cannot build Java 25 and a test that fails in the pipeline is
worse than no test. It passed (3 tests, 0 Checkstyle violations) and was then
committed; the delivery run on that push verified it a second time.

Nothing this pass could produce was verifiable by the model that produced it:
no cluster, no build, no GitHub credentials. That is the same constraint as the
capability in [docs/ai-capability.md](docs/ai-capability.md), and the same
answer — its output is a list of claims, and the rebuild is what checks them.

## What I would not use it for again unchanged

Anything where the model's output is trusted without a way to check it. The one AI
capability designed for this platform ([docs/ai-capability.md](docs/ai-capability.md))
is deliberately comment-only, failure-silent, and unable to gate a promotion —
because the honest lesson from this log is that the first answer is frequently
wrong in a way that reads convincing.
