SHELL := /bin/bash
.SHELLFLAGS := -Eeuo pipefail -c
.DEFAULT_GOAL := help
S := scripts
VERSION := $(shell sed -n 's/^PROJECT_VERSION=\([^ ]*\).*/\1/p' config/project.env)

# Scripts écrits pendant le run (phases 1 et 3) : message clair s'ils n'existent pas encore.
define need
@test -x $(S)/$(1) || { echo "$(S)/$(1) n'existe pas encore (voir PLAN.md)"; exit 1; }
endef

help: ## Affiche cette aide
	@echo "zorin-nomade $(VERSION) — make <cible> :"
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{ printf "  %-16s %s\n", $$1, $$2 }'

doctor: ## Vérifie l'hôte : outils, KVM, OVMF, espace disque (STRICT=1 : garde-fous Claude bloquants)
	@$(S)/host-doctor.sh $(if $(STRICT),--strict)

PY := $(shell find config/rootfs scripts tests -name '*.py' -not -path '*/__pycache__/*' 2>/dev/null)

lint: ## shellcheck sur tous les scripts, syntaxe des scripts Python
	@shellcheck $(S)/*.sh $(S)/bssh $$(find $(S) -mindepth 2 -name '*.sh' 2>/dev/null) \
	  config/rootfs/usr/local/lib/nomade/*.sh $(wildcard config/rootfs/usr/local/bin/nomade-diag)
	@python3 -I -B -c 'import ast, sys; [ast.parse(open(f, encoding="utf-8").read(), f) for f in sys.argv[1:]]' $(PY)
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

diag-cle: ## Diagnostic d'une clé avant déploiement : KEY=… (sudo : lectures ; COMPLET=1 : EFFACE la clé)
	@[[ -n "$(KEY)" ]] || { echo "Précise KEY=/dev/disk/by-id/usb-… (ls -l /dev/disk/by-id/ | grep usb)"; exit 1; }
	@$(S)/diag-cle.sh --cible "$(KEY)" $(if $(COMPLET),--complet) $(if $(DUREE),--duree $(DUREE)) $(if $(BRUT),--brut)

diag-cle-test: ## Essai de diag-cle dans la VM de build (fichier, loop, contrefaçon simulée)
	@$(S)/diag-cle-test.sh

diag-rapport: ## Rassemble les diagnostics dans docs/terrain.md (SRC=…/NOMADE-DATA/nomade-diag : copie d'abord)
	@[[ $$EUID -ne 0 ]] || { echo "make diag-rapport : sans sudo"; exit 1; }
	@python3 -I -B config/rootfs/usr/local/lib/nomade/diag.py rapport --depot "$(CURDIR)" $(if $(SRC),--src "$(SRC)")

all: image test ## Chaîne complète : image puis tests

ci: lint ## Ce que la CI exécute à chaque push : lint, garde-fous, tests des diagnostics
	@$(S)/test-guards.sh
	@python3 -I -B tests/diag/test_diag.py

clean: ## Supprime out/ (images et résultats de test)
	rm -rf out

distclean: clean builder-destroy ## Supprime aussi la VM de build et le cache
	rm -rf cache .builder

.PHONY: help doctor lint iso builder builder-status builder-down builder-destroy image test \
        test-gui deploy-test deploy diag-cle diag-cle-test diag-rapport all ci clean distclean
