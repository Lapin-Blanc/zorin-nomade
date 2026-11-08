SHELL := /bin/bash
.SHELLFLAGS := -Eeuo pipefail -c
.DEFAULT_GOAL := help
S := scripts

# Scripts écrits pendant le run (phases 1 et 3) : message clair s'ils n'existent pas encore.
define need
@test -x $(S)/$(1) || { echo "$(S)/$(1) n'existe pas encore (voir PLAN.md)"; exit 1; }
endef

help: ## Affiche cette aide
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{ printf "  %-16s %s\n", $$1, $$2 }'

doctor: ## Vérifie l'hôte : outils, KVM, OVMF, garde-fous, espace disque
	@$(S)/host-doctor.sh

lint: ## shellcheck sur tous les scripts
	@shellcheck $(S)/*.sh $(S)/bssh $$(find $(S) -mindepth 2 -name '*.sh' 2>/dev/null) \
	  config/rootfs/usr/local/lib/nomade/*.sh
	@echo "lint : ok"

iso: ## Télécharge et vérifie l'ISO Zorin (config/iso.env)
	@$(S)/fetch-iso.sh >/dev/null

builder: ## Démarre la VM de build (la crée si besoin)
	@$(S)/builder.sh up

builder-status: ## État de la VM de build
	@$(S)/builder.sh status

builder-down: ## Arrête la VM de build
	@$(S)/builder.sh down

builder-destroy: ## Supprime la VM de build (le cache est conservé)
	@$(S)/builder.sh destroy

image: iso builder ## Construit l'image dans la VM de build → out/latest.img
	$(call need,build-image.sh)
	@$(S)/build-image.sh

test: ## Démarre out/latest.img dans QEMU (Secure Boot on puis off) et lit l'autotest
	@$(S)/test-image.sh

test-gui: ## Démarre out/latest.img dans une fenêtre, pour regarder
	@$(S)/test-image.sh --gui

deploy-test: builder ## Déploiement chiffré sur un fichier puis démarrage (RUNS=2 : rejoué deux fois)
	$(call need,deploy-test.sh)
	@$(S)/deploy-test.sh $(if $(RUNS),--runs $(RUNS))

deploy: ## (Fabien, avec sudo) sudo make deploy KEY=/dev/disk/by-id/usb-…
	@[[ $$EUID -eq 0 ]] || { echo "À lancer par Fabien : sudo make deploy KEY=/dev/disk/by-id/usb-…"; exit 1; }
	@[[ -n "$(KEY)" ]] || { echo "Précise KEY=/dev/disk/by-id/usb-… (ls -l /dev/disk/by-id/ | grep usb)"; exit 1; }
	$(call need,deploy.sh)
	@$(S)/deploy.sh --target "$(KEY)"

all: image test ## Chaîne complète : image puis tests

ci: lint ## Ce que la CI exécute à chaque push : lint et garde-fous
	@$(S)/test-guards.sh

clean: ## Supprime out/ (images et résultats de test)
	rm -rf out

distclean: clean builder-destroy ## Supprime aussi la VM de build et le cache
	rm -rf cache .builder

.PHONY: help doctor lint iso builder builder-status builder-down builder-destroy image test \
        test-gui deploy-test deploy all ci clean distclean
