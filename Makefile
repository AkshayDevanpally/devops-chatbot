.PHONY: help compose test k3s apparmor registry platform build deploy-dev deploy-qa deploy-prod tls trust-ca jenkins jenkins-agent jenkins-password verify logs clean backups backup-now backup-status backup-test backup-download db-restore backup-offsite-setup backup-offsite-now backup-admin-password db-tls tunnel-up tunnel-test tunnel-down tunnel-status burst-prepare burst-up burst-ready burst-test burst-down burst-status guardrails-up guardrails-test guardrails-status guardrails-reset alerts alerts-topic alerts-test alerts-status lan-share-ca sleep-setup sleep-status sleep-now stay-awake allow-sleep wol-test alert-test pi-gateway pi-test pi-simulate pi-status pi-quiet

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

backups:       ## nightly backups, off-site every 3 days, restore test, backup-ops for Pulse (install/update)
	./scripts/10-backups.sh install

backup-offsite-setup: ## S3 bucket for off-site copies + write-only key into the cluster (once; rotates the key)
	./scripts/10-backups.sh offsite-setup

backup-offsite-now: ## copy the newest backup to S3 right away
	./scripts/10-backups.sh offsite-now

backup-admin-password: ## set the password for "Back up now" on the Pulse page
	./scripts/10-backups.sh admin-password

backup-now:    ## take a Postgres backup right away
	./scripts/10-backups.sh now

backup-status: ## list backups on the server and recent runs
	./scripts/10-backups.sh status

backup-test:   ## restore the newest backup into a throwaway Postgres and check it
	./scripts/10-backups.sh test

backup-download: ## copy the newest backup to ./backups (STAMP=... for another one)
	./scripts/10-backups.sh download

db-restore:    ## replace one env's database with a backup (ENV=dev|qa|prod STAMP=...)
	./scripts/10-backups.sh restore $(ENV) $(STAMP)

db-tls:        ## TLS for Postgres from the local CA + tunnel rules (Phase 5; needs make tls)
	./scripts/11-db-tls.sh

tunnel-up:     ## Phase 5 test: tiny AWS WireGuard endpoint + home wg0 (needs db-tls; costs ~1 cent/hour)
	./scripts/12-tunnel.sh up

tunnel-test:   ## check Postgres over the tunnel from the AWS side
	./scripts/12-tunnel.sh test

tunnel-down:   ## home wg0 down + destroy everything in AWS
	./scripts/12-tunnel.sh down

tunnel-status: ## AWS endpoint and wg0 state
	./scripts/12-tunnel.sh status

burst-prepare: ## Phase 6, once: firewall rules on wg0 for the AWS burst node (sudo)
	sudo ./scripts/13-burst.sh prepare

burst-up:      ## Phase 6: AWS Spot node joins k3s, runs extra prod chat-api + Ollama (~$0.06/h)
	./scripts/13-burst.sh up

burst-ready:   ## finish burst-up after running its sudo lines
	./scripts/13-burst.sh ready

burst-test:    ## check the burst node, its pods, Postgres over TLS, the model, the Capacity page
	./scripts/13-burst.sh test

burst-down:    ## burst pods off, node removed, wg0 down, destroy everything in AWS
	./scripts/13-burst.sh down

burst-status:  ## AWS node, wg0 and pods on the burst node
	./scripts/13-burst.sh status

guardrails-up: ## AWS $10/month budget: emails, then deny-create + kill switch at 100% (stays up, $0)
	./scripts/14-guardrails.sh up

guardrails-test: ## kill switch dry run: what it would terminate right now
	./scripts/14-guardrails.sh test

guardrails-status: ## spend this month, budget action state, deny policy attached?
	./scripts/14-guardrails.sh status

guardrails-reset: ## after a cut-off: give the Terraform user its create rights back
	./scripts/14-guardrails.sh reset

alerts:        ## alerts to your phone via ntfy: Alertmanager, ntfy-bridge, rules (install/update)
	./scripts/15-alerts.sh install

alerts-topic:  ## show the private ntfy topic to subscribe to (NEW=1 makes a new one)
	./scripts/15-alerts.sh topic $(if $(NEW),--new,)

alerts-test:   ## send a test alert through the whole chain to your phone
	./scripts/15-alerts.sh test

alerts-status: ## rules loaded, alerts firing now, last notifications sent
	./scripts/15-alerts.sh status

lan-share-ca:  ## sudo: serve the home CA certificate on the LAN for 10 min, to install on a phone or laptop
	sudo ./scripts/16-lan-access.sh share-ca

sleep-setup:   ## Phase 7, sudo: Wake-on-LAN on; sleep when idle 30 min; wake 07:50 IST for backups
	sudo ./scripts/17-sleep.sh setup

sleep-status:  ## would the server sleep now, and if not, why
	./scripts/17-sleep.sh status

sleep-now:     ## sudo: sleep right away; MINUTES=2 wakes it by itself after 2 min (else 07:50 IST or Wake-on-LAN)
	sudo ./scripts/17-sleep.sh now $(MINUTES)

wol-test:      ## sudo: find where Wake-on-LAN breaks (card setting, Wi-Fi->cable delivery, real wake ~3 min)
	sudo ./scripts/17-sleep.sh wol-test

alert-test:    ## sudo: sleep 5 min without telling the Pi; your phone should get "server down", then "back"
	sudo ./scripts/17-sleep.sh alert-test

stay-awake:    ## never sleep until allow-sleep
	./scripts/17-sleep.sh stay-awake

allow-sleep:   ## sleep when idle again
	./scripts/17-sleep.sh allow-sleep

pi-gateway:    ## Phase 7: set up the Raspberry Pi gateway (PI=user@ip; asks the Pi's sudo password)
	./scripts/18-pi-gateway.sh install

pi-test:       ## checks through the Pi: pass-through, names announced, waker sees the server
	./scripts/18-pi-gateway.sh test

pi-simulate:   ## pretend the server sleeps: waking page, redirect, magic packet (Pi's sudo password)
	./scripts/18-pi-gateway.sh simulate

pi-status:     ## Pi services, what the waker and the watcher see
	./scripts/18-pi-gateway.sh status

pi-quiet:      ## planned work (reboot, BIOS): no "server down" alert from the Pi for MINUTES (default 30)
	./scripts/18-pi-gateway.sh quiet $(or $(MINUTES),30)

verify:        ## functional + security checks (ENV=dev|qa|prod)
	./scripts/07-verify.sh $(or $(ENV),dev)

logs:          ## tail chat-api logs (ENV=dev|qa|prod)
	kubectl -n chatbot-$(or $(ENV),dev) logs -l app.kubernetes.io/component=api -f --tail=50

clean:         ## remove the three app releases (keeps platform + data)
	-helm uninstall chatbot-dev -n chatbot-dev
	-helm uninstall chatbot-qa -n chatbot-qa
	-helm uninstall chatbot-prod -n chatbot-prod
