SHELL := /bin/bash
DEV_CTX  := kind-kind-dev
PROD_CTX := kind-kind-prod
REPO_URL := git@github.com:itayna/terasky-platform-ha.git

.PHONY: help bootstrap bootstrap-dev bootstrap-prod repo-secret apps onboard status passwords clean

help:
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t26

bootstrap: bootstrap-dev bootstrap-prod ## Create + provision both kind clusters
	@echo
	@echo "Next: make repo-secret DEPLOY_KEY=<path-to-deploy-key> && make apps"

bootstrap-dev: ## kind-dev + Argo CD + sealed-secrets + Kyverno + signature policy
	clusters/kind-dev/bootstrap.sh

bootstrap-prod: ## kind-prod + the above + Argo Rollouts
	clusters/kind-prod/bootstrap.sh

repo-secret: ## Give Argo CD read access to this repo (DEPLOY_KEY=~/.ssh/key)
	@test -n "$(DEPLOY_KEY)" || { echo "usage: make repo-secret DEPLOY_KEY=~/.ssh/key"; exit 1; }
	@for ctx in $(DEV_CTX) $(PROD_CTX); do \
	  kubectl --context $$ctx -n argocd create secret generic terasky-platform-ha-repo \
	    --from-literal=type=git --from-literal=url=$(REPO_URL) \
	    --from-file=sshPrivateKey=$(DEPLOY_KEY) \
	    --dry-run=client -o yaml | kubectl --context $$ctx apply -f - ; \
	  kubectl --context $$ctx -n argocd label secret terasky-platform-ha-repo \
	    argocd.argoproj.io/secret-type=repository --overwrite ; \
	done

apps: ## Register the two root Applications (once per cluster, ever)
	kubectl --context $(DEV_CTX)  apply -f gitops/argocd-apps/root-dev.yaml
	kubectl --context $(PROD_CTX) apply -f gitops/argocd-apps/root-prod.yaml

onboard: ## Scaffold a service onto the paved road (SERVICE=name [OWNER=handle])
	@test -n "$(SERVICE)" || { echo "usage: make onboard SERVICE=my-service [OWNER=gh-handle]"; exit 1; }
	bin/platformctl new $(SERVICE) $(if $(OWNER),--owner $(OWNER),) $(ONBOARD_FLAGS)

status: ## Sync/health of both environments
	@for ctx in $(DEV_CTX) $(PROD_CTX); do \
	  echo "== $$ctx"; \
	  kubectl --context $$ctx get applications.argoproj.io -n argocd; \
	  kubectl --context $$ctx get pods -n default; \
	done

passwords: ## Print the initial Argo CD admin passwords
	@for ctx in $(DEV_CTX) $(PROD_CTX); do \
	  printf '%s: ' $$ctx; \
	  kubectl --context $$ctx -n argocd get secret argocd-initial-admin-secret \
	    -o jsonpath='{.data.password}' | base64 -d; echo; \
	done

clean: ## Delete both clusters
	kind delete cluster --name kind-dev
	kind delete cluster --name kind-prod
