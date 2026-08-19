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
`cd` into a scratch directory and let `gh` clone into `./<service>`.

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

## What I would not use it for again unchanged

Anything where the model's output is trusted without a way to check it. The one AI
capability designed for this platform ([docs/ai-capability.md](docs/ai-capability.md))
is deliberately comment-only, failure-silent, and unable to gate a promotion —
because the honest lesson from this log is that the first answer is frequently
wrong in a way that reads convincing.
