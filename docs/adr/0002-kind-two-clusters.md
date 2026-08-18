# ADR-0002: Local `kind`, two clusters rather than two namespaces

- **Status**: Accepted
- **Date**: 2026-08-17

## Context

The environment must cost nothing and be reproducible by a reviewer from the
README. "Dev" and "prod" must be separate enough that the promotion flow and the
rollback story are real rather than cosmetic.

## Decision

Two `kind` clusters, `kind-dev` and `kind-prod`, each bootstrapped by a script
in `clusters/kind-*/`. Each cluster runs its own Argo CD, sealed-secrets
controller and Kyverno; `kind-prod` additionally runs Argo Rollouts.

## Consequences

- Cluster-scoped changes — the Kyverno `ClusterPolicy`, a Kyverno version bump,
  a CRD upgrade — can be tried in dev and observed failing there. That is the
  main day-2 rehearsal this setup buys.
- Each cluster has its own sealed-secrets keypair, so a `SealedSecret` committed
  for dev genuinely cannot decrypt in prod. That is a property to demonstrate,
  not an inconvenience.
- Cost: roughly double the local resources, two Argo CD instances to upgrade,
  and no shared ingress, so canary weights are approximated by replica counts
  ([ADR-0003](0003-argo-rollouts.md)).

## Alternatives rejected

**One cluster, `dev` and `prod` namespaces.** Half the resources and a single
Argo CD to operate. Rejected because the interesting failure modes here are
cluster-scoped: a bad admission policy or a controller upgrade would hit both
"environments" simultaneously, which is exactly the blast radius a promotion flow
is supposed to contain. It also makes the sealed-secrets key boundary
meaningless.

**minikube.** Mature and well documented. Rejected because `kind` nodes are
plain Docker containers — faster to create and delete repeatedly, multi-node by
config, and the same tool used in most CI systems, so the local setup and a
future CI-based test of the platform stay identical.

**k3d.** Very close second, and lighter (k3s). Rejected on the grounds that k3s
substitutes components (Traefik, servicelb, its own storage defaults) that
differ from upstream Kubernetes; for a platform whose whole point is admission
control and controller upgrades, matching upstream behaviour matters more than
the memory saved.

**Free-tier hosted Kubernetes.** Permitted by the assignment, but every free
tier either expires or eventually asks for a payment method, which breaks the
"reviewer can reproduce it at zero cost" requirement.
