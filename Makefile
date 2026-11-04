.PHONY: help compose test k3s apparmor registry platform build deploy-dev deploy-qa deploy-prod tls trust-ca jenkins jenkins-agent jenkins-password verify logs clean

# k3s's kubectl reads the root-only /etc/rancher/k3s/k3s.yaml unless told otherwise.
# Use the user copy that `make k3s` puts in ~/.kube/config.
export KUBECONFIG ?= $(HOME)/.kube/config

help:          ## list commands
	@grep -E '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

compose:       ## quick test with docker compose (http://localhost:8080)
	docker compose up --build

test:          ## lint + retention tests against a throwaway Postgres
	./scripts/test.sh

k3s:           ## install hardened k3s + helm (sudo)
	sudo ./scripts/01-install-k3s.sh

apparmor:      ## load the pods' AppArmor profile on this node (sudo)
	sudo ./scripts/01a-apparmor.sh

registry:      ## start local registry on localhost:5000
	./scripts/02-local-registry.sh

platform:      ## namespaces, policies, secrets, Ollama, Postgres
	./scripts/04-platform.sh

tls:           ## cert-manager + local CA + HTTP->HTTPS redirect (Phase 3.4)
	./scripts/08-tls.sh

trust-ca:      ## trust the local CA on this machine (sudo)
	sudo ./scripts/08a-trust-ca.sh

jenkins:       ## Jenkins controller in k3s (REPO_URL=git@github.com:<you>/<repo>.git) (Phase 4)
	./scripts/09-jenkins.sh

jenkins-agent: ## build agent on this host as a systemd service (sudo)
	sudo ./scripts/09a-jenkins-agent.sh

jenkins-password: ## print the Jenkins admin password
	@kubectl -n ci get secret jenkins-secrets -o jsonpath='{.data.admin-password}' | base64 -d; echo

build:         ## build, scan and push images tagged with the git SHA
	./scripts/03-build-push.sh

deploy-dev:    ## deploy last built tag to dev
	./scripts/06-deploy.sh dev

deploy-qa:     ## promote the same tag to qa
	./scripts/06-deploy.sh qa

deploy-prod:   ## promote the same tag to prod (asks for confirmation)
	./scripts/06-deploy.sh prod

verify:        ## functional + security checks (ENV=dev|qa|prod)
	./scripts/07-verify.sh $(or $(ENV),dev)

logs:          ## tail chat-api logs (ENV=dev|qa|prod)
	kubectl -n chatbot-$(or $(ENV),dev) logs -l app.kubernetes.io/component=api -f --tail=50

clean:         ## remove the three app releases (keeps platform + data)
	-helm uninstall chatbot-dev -n chatbot-dev
	-helm uninstall chatbot-qa -n chatbot-qa
	-helm uninstall chatbot-prod -n chatbot-prod
