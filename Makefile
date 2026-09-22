# =============================================================================
# LLM spend gateway
#
#   make help     what each target does
#   make check    verify prerequisites without changing anything
#   make infra    terraform apply
#   make seed     push configuration into the key value map
#   make deploy   build and deploy the proxy bundle
#   make smoke    exercise the deployed gateway
#
# First run, in order:  make check infra seed deploy smoke
# =============================================================================

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

TF := terraform -chdir=terraform

.PHONY: help
help:
	@printf '\n\033[1mSetup\033[0m\n'
	@printf '  %-14s %s\n' 'init'      'copy example config files into place (does not overwrite)'
	@printf '  %-14s %s\n' 'check'     'preflight: tools, config, Apigee, IAM, endpoint, IdP'
	@printf '\n\033[1mInfrastructure\033[0m\n'
	@printf '  %-14s %s\n' 'plan'      'terraform plan'
	@printf '  %-14s %s\n' 'infra'     'terraform apply'
	@printf '  %-14s %s\n' 'outputs'   'show terraform outputs'
	@printf '\n\033[1mGateway\033[0m\n'
	@printf '  %-14s %s\n' 'seed'      'push pricing, budgets and runtime-config into the KVM'
	@printf '  %-14s %s\n' 'build'     'substitute placeholders into a bundle, without deploying'
	@printf '  %-14s %s\n' 'deploy'    'build, ensure data collectors, import and deploy'
	@printf '  %-14s %s\n' 'undeploy'  'undeploy the current revision (stops serving)'
	@printf '\n\033[1mVerification\033[0m\n'
	@printf '  %-14s %s\n' 'lint'      'validate JSON config and XML bundle syntax locally'
	@printf '  %-14s %s\n' 'smoke'     'end-to-end tests against the deployed gateway'
	@printf '  %-14s %s\n' 'observe'   'switch to observation mode: meter everything, refuse nothing'
	@printf '  %-14s %s\n' 'enforce'   'switch enforcement on'
	@printf '\n'

# -----------------------------------------------------------------------------
# Guard: nearly every target needs config/env.sh, and the failure without it is
# an unbound-variable error from deep inside a script.
# -----------------------------------------------------------------------------
.PHONY: require-env
require-env:
	@test -f config/env.sh || { \
	  echo "config/env.sh is missing. Run: make init"; exit 1; }

.PHONY: init
init:
	@for f in env.sh:env.example.sh \
	          pricing.json:pricing.example.json \
	          budgets.json:budgets.example.json \
	          runtime-config.json:runtime-config.example.json; do \
	    dst="config/$${f%%:*}"; src="config/$${f##*:}"; \
	    if [ -f "$$dst" ]; then echo "  keeping $$dst"; \
	    else cp "$$src" "$$dst"; echo "  created $$dst"; fi; \
	  done
	@if [ -f terraform/terraform.tfvars ]; then echo "  keeping terraform/terraform.tfvars"; \
	 else cp terraform/terraform.tfvars.example terraform/terraform.tfvars; \
	      echo "  created terraform/terraform.tfvars"; fi
	@printf '\nEdit those four files, then: make check\n\n'

.PHONY: check
check: require-env
	@bash scripts/preflight-check.sh

# -----------------------------------------------------------------------------
# Local validation. Cheap, offline, and catches the class of mistake that would
# otherwise be found by a failed import several minutes into a deploy.
# -----------------------------------------------------------------------------
.PHONY: lint
lint:
	@echo "==> JSON"
	@for f in config/*.json; do \
	  jq empty "$$f" && echo "    ok   $$f" || { echo "    FAIL $$f"; exit 1; }; \
	 done
	@echo "==> XML"
	@if command -v xmllint >/dev/null 2>&1; then \
	   find proxy -name '*.xml' -print0 | xargs -0 -n1 xmllint --noout \
	     && echo "    ok   all bundle XML is well formed"; \
	 else echo "    skip xmllint not installed"; fi
	@echo "==> Policy references"
	@bash -c 'missing=0; \
	  for p in $$(grep -ho "<Name>[A-Za-z0-9-]*</Name>" proxy/*/apiproxy/proxies/*.xml \
	              | sed -e "s/<Name>//" -e "s|</Name>||" | sort -u); do \
	    if [ ! -f "proxy/llm-gateway/apiproxy/policies/$$p.xml" ]; then \
	      echo "    FAIL flow references missing policy: $$p"; missing=1; fi; \
	  done; \
	  [ $$missing -eq 0 ] && echo "    ok   every referenced policy exists"; exit $$missing'
	@echo "==> Placeholders"
	@printf '    %s build-time placeholder(s) in the bundle: %s\n' \
	  "$$(grep -rho '@@[A-Z_]*@@' proxy | sort -u | wc -l | tr -d ' ')" \
	  "$$(grep -rho '@@[A-Z_]*@@' proxy | sort -u | tr '\n' ' ')"

# -----------------------------------------------------------------------------
# Infrastructure
# -----------------------------------------------------------------------------
.PHONY: plan
plan:
	@$(TF) init -input=false
	@$(TF) plan

.PHONY: infra
infra:
	@$(TF) init -input=false
	@$(TF) apply

.PHONY: outputs
outputs:
	@$(TF) output

# -----------------------------------------------------------------------------
# Gateway
# -----------------------------------------------------------------------------
.PHONY: seed
seed: require-env
	@bash scripts/seed-kvm.sh

.PHONY: build
build: require-env lint
	@BUILD_ONLY=1 bash -c 'source config/env.sh; \
	  echo "Bundle would be built into $${BUILD_DIR:-.build}/$${PROXY_NAME}"; \
	  echo "Run make deploy to build and deploy."'

.PHONY: deploy
deploy: require-env lint
	@bash scripts/deploy-proxy.sh

.PHONY: undeploy
undeploy: require-env
	@bash -c 'source config/env.sh; \
	  t=$$(gcloud auth print-access-token); \
	  rev=$$(apigeecli apis listdeploy -n "$$PROXY_NAME" -e "$$APIGEE_ENV" -o "$$APIGEE_ORG" -t "$$t" \
	         | jq -r ".deployments[0].revision"); \
	  echo "Undeploying revision $$rev - the gateway will stop serving."; \
	  apigeecli apis undeploy -n "$$PROXY_NAME" -v "$$rev" -e "$$APIGEE_ENV" -o "$$APIGEE_ORG" -t "$$t"'

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
.PHONY: smoke
smoke: require-env
	@bash scripts/smoke-test.sh

# -----------------------------------------------------------------------------
# Enforcement switch.
#
# Two targets rather than a documented JSON edit, because this is the change
# most likely to be made in a hurry by someone who did not write the config.
#
# Observation mode is not a debug setting. It is the intended first phase of any
# rollout: meter, log and report for long enough to see what people's work
# actually costs, then set caps from that data. Caps chosen before the data
# exists are guesses, and a guess that is too low arrives as an outage.
# -----------------------------------------------------------------------------
.PHONY: observe
observe: require-env
	@jq '.features.enforce = false' config/runtime-config.json > config/.rc.tmp \
	  && mv config/.rc.tmp config/runtime-config.json
	@bash scripts/seed-kvm.sh

.PHONY: enforce
enforce: require-env
	@jq '.features.enforce = true' config/runtime-config.json > config/.rc.tmp \
	  && mv config/.rc.tmp config/runtime-config.json
	@bash scripts/seed-kvm.sh

.PHONY: clean
clean:
	@rm -rf .build
	@echo "removed .build"
