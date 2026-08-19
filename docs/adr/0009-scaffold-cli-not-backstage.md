# ADR-0009: A scaffold script and a generated catalog, not a portal

- **Status**: Accepted
- **Date**: 2026-08-19

## Context

The paved road needs two things a product team can use without the platform team:
a way to create a service that is compliant on day one, and a way to answer "what
services exist, who owns them, what is deployed where, and are they still
compliant".

Backstage is the default answer to both. The question is whether a portal is the
capability or the packaging of one.

## Decision

- **`bin/platformctl new <service>`** — renders `templates/service-v1/` into
  `environments/{dev,prod}/<service>/` and a child Argo CD `Application` per
  environment, creates the service repository from the reference app, appends the
  service to `catalog/services.yaml`, and opens one pull request. `--dry-run`
  prints the tree with no side effects.
- **`catalog/services.yaml`** — identity only: name, repository, onboarding date.
- **`bin/scorecard`** — reads the catalog, derives every compliance column from a
  source of truth, writes `CATALOG.md`, and exits non-zero on a red row. It runs
  daily and on every push to `main` (`.github/workflows/scorecard.yml`).

The catalog deliberately stores nothing that can be derived. The owner comes from
the service repository's `CODEOWNERS`, the pinned pipeline version from its
`delivery.yml`, the deployed tags from the kustomizations, the signature and SBOM
from the registry, and the promotion trail from this repository's history.

## Rationale

- **Registration is a merged pull request, not a command.** Because the root
  Applications are app-of-apps over `gitops/argocd-apps/<env>/`, adding a child
  Application file *is* the registration. Nobody runs `kubectl` to onboard, which
  is what makes "no platform team in the loop" literally true rather than
  aspirational.
- **Nothing in the catalog can drift**, because nothing in it is a second copy of
  a fact. A catalog that lists an owner who left is worse than no catalog.
- **A red row fails a check.** Compliance that only renders is compliance nobody
  acts on; the scorecard's exit code is the product, `CATALOG.md` is the receipt.
- **The scaffold's templates are generated from the reference app**, so the golden
  path cannot drift from something that demonstrably builds, deploys, signs and
  canaries today.

## Consequences

- No web UI. Discovery is `CATALOG.md` in this repository and the Argo CD UI for
  live state. For a handful of services that is enough; at ~20 services the
  markdown table stops being the right surface.
- `platformctl` is bash. It is readable and dependency-free (`gh`, `git`,
  `python3` for the catalog append), and it will not grow into a control plane —
  when it wants to, that is the signal to adopt one (see
  [FUTURE.md](../../FUTURE.md)).
- The scaffold creates the service repository from the reference app, so a new
  service starts as a working Java service with Actuator probes rather than an
  empty repository. The team replaces the source; the pipeline contract is already
  satisfied.
- One human step remains, on purpose: reviewing and merging the onboarding pull
  request. It is the audit record of a service joining the platform.

## Alternatives rejected

**Backstage with software templates and a catalog.** The real answer at scale: a
UI product teams can use without reading YAML, plugin ecosystem, TechDocs, and a
catalog with ownership and relations. Rejected for this platform now because it
needs a database, an operator, an auth integration and a plugin build to run, and
because everything it would show here is already true in Git — Backstage's
templates would call the same pipeline, its catalog would read the same
`CODEOWNERS`, its scorecard plugin would assert the same rows. It packages this
capability; it does not create it. Trigger for revisiting: enough services that a
markdown table is unreadable, or a second team that will not use a CLI.

**Cookiecutter or Copier.** Purpose-built templating with variables, prompts and
the ability to re-apply a template to an existing project — genuinely better than
`sed` at rendering. Rejected because rendering is the small half of onboarding:
the work is creating the repository, wiring the secret, registering both Argo
Applications and opening the pull request. That would still be a script around the
templater, and it would add a Python dependency to get `sed` with prompts.

**Crossplane compositions as the onboarding API.** A `Service` claim, reconciled
into repository, manifests and registration — declarative and continuously
reconciled rather than a one-shot scaffold. Rejected as disproportionate here:
this platform provisions no cloud infrastructure, so Crossplane would be
introduced solely to run a GitHub provider, and onboarding would become
debuggable only through composition status. Stays in `FUTURE.md`, where it earns
its place as soon as a service needs a database or a bucket.

**A `platformctl` that applies manifests directly with `kubectl`.** Fewer steps
and instant feedback. Rejected because it puts cluster credentials in the
onboarding path and creates state no reconciler owns — the exact push-based
failure mode [ADR-0007](0007-argocd-vs-flux.md) rejected.
