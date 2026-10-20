.DEFAULT_GOAL := help

SOUL_TRIAL ?= soul-trial
SOUL_LINT  ?= soul-lint

.PHONY: help lint trial check

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN{FS=":.*?## "}{printf "%-18s %s\n", $$1, $$2}'

lint: ## Validate the destiny manifest and the test wrapper
	$(SOUL_LINT) validate-destiny destiny.yml
	$(SOUL_LINT) validate-service _trial/service.yml
	$(SOUL_LINT) validate-scenario --service-name dragonfly _trial/scenario/apply/main.yml

trial: ## Run the render-only test suite
	$(SOUL_TRIAL) run _trial

check: lint trial ## Lint, then run the suite
