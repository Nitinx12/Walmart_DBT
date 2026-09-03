# ==============================================================================
# Walmart Data Pipeline — Makefile
# Production task runner: static checks, unit tests, the 8-stage data
# pipeline, and build/release, all wired through uv.
# ==============================================================================

# ---- Environment -------------------------------------------------------------
ifneq (,$(wildcard ./.env))
    include .env
    export
endif

export PYTHONPATH := $(PWD)
export PYTHONIOENCODING := utf-8

SHELL         := /bin/bash
.SHELLFLAGS   := -eu -o pipefail -c

UV       := uv
PYTHON   := $(UV) run python
DBT_DIR  := walmart_dbt
SRC_DIRS := scripts pipeline
UNIT_DIR := tests/unit
VERSION  := $(shell $(UV) run python -c "import tomllib; print(tomllib.load(open('pyproject.toml','rb'))['project']['version'])" 2>/dev/null || echo "0.0.0-dev")

# Color helpers — degrade silently on terminals without tput
BOLD   := $(shell tput bold 2>/dev/null)
GREEN  := $(shell tput setaf 2 2>/dev/null)
YELLOW := $(shell tput setaf 3 2>/dev/null)
RESET  := $(shell tput sgr0 2>/dev/null)

.DEFAULT_GOAL := help

.PHONY: help install install-dev pre-commit-install \
        lint lint-fix format format-check type-check static-checks unit-test ci \
        preflight extract test-bronze dbt-silver test-silver dbt-gold test-gold gx-tests \
        data-pipeline all build clean clean-venv

# ---- Help ----------------------------------------------------------------
help: ## Show this help
	@echo "$(BOLD)Walmart Data Pipeline$(RESET) — available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-18s$(RESET) %s\n", $$1, $$2}'

# ---- Setup -----------------------------------------------------------------
install: ## Install runtime dependencies
	$(UV) sync

install-dev: ## Install runtime + dev dependencies (lint/test/type-check tools)
	$(UV) sync --extra dev

pre-commit-install: install-dev ## Install git pre-commit hooks
	$(UV) run pre-commit install

# ---- Lint / Format / Type-check --------------------------------------------
lint: ## Lint Python (ruff), SQL (sqlfluff), and validate the dbt project parses
	@echo "$(BOLD)>> ruff check$(RESET)"
	$(UV) run ruff check $(SRC_DIRS)
	@echo "$(BOLD)>> sqlfluff lint$(RESET)"
	$(UV) run sqlfluff lint tests $(DBT_DIR)/models
	@echo "$(BOLD)>> dbt parse (validates the project graph without touching data)$(RESET)"
	cd $(DBT_DIR) && $(UV) run dbt parse --quiet

lint-fix: ## Auto-fix lint issues where possible
	$(UV) run ruff check --fix $(SRC_DIRS)
	$(UV) run sqlfluff fix tests $(DBT_DIR)/models

format: ## Format Python code in place
	$(UV) run ruff format $(SRC_DIRS)

format-check: ## Check formatting without modifying files (CI-safe)
	$(UV) run ruff format --check $(SRC_DIRS)

type-check: ## Static type-check Python with mypy
	$(UV) run mypy $(SRC_DIRS)

static-checks: lint format-check type-check ## Run all static checks (no tests, no data movement)

# ---- Unit tests ---------------------------------------------------------
unit-test: ## Run fast unit tests (no live DB/Spark required)
	$(UV) run pytest $(UNIT_DIR) -v

# ---- CI entrypoint -----------------------------------------------------
ci: static-checks unit-test ## CI entrypoint: static checks + unit tests (safe to run without live infra)

# ---- Data pipeline (8-stage, strict order, fails fast) ----------------------
preflight: ## [0/7] Verify environment/dependency compatibility
	@echo "------------------------------------------------------------"
	@echo " STEP 0 / 7  -  PREFLIGHT (dependency check)"
	@echo "------------------------------------------------------------"
	$(PYTHON) -c "import pyspark; assert pyspark.__version__.startswith('3.5'), f'Incompatible PySpark version: {pyspark.__version__}. Requires 3.5.x'"

extract: ## [1/7] Extract MongoDB collections into Bronze
	@echo "------------------------------------------------------------"
	@echo " STEP 1 / 7  -  EXTRACT (MongoDB to Bronze)"
	@echo "------------------------------------------------------------"
	$(PYTHON) scripts/extract.py

test-bronze: ## [2/7] Run Bronze-layer SQL tests
	@echo "------------------------------------------------------------"
	@echo " STEP 2 / 7  -  BRONZE SQL TESTS"
	@echo "------------------------------------------------------------"
	$(PYTHON) scripts/sql_test.py tests/bronze

dbt-silver: ## [3/7] Build + test Silver dbt models
	@echo "------------------------------------------------------------"
	@echo " STEP 3 / 7  -  DBT SILVER (build and test)"
	@echo "------------------------------------------------------------"
	cd $(DBT_DIR) && $(UV) run dbt run --select silver && $(UV) run dbt test --select silver

test-silver: ## [4/7] Run Silver-layer SQL tests
	@echo "------------------------------------------------------------"
	@echo " STEP 4 / 7  -  SILVER SQL TESTS"
	@echo "------------------------------------------------------------"
	$(PYTHON) scripts/sql_test.py tests/silver

dbt-gold: ## [5/7] Build + test Gold dbt models
	@echo "------------------------------------------------------------"
	@echo " STEP 5 / 7  -  DBT GOLD (build and test)"
	@echo "------------------------------------------------------------"
	cd $(DBT_DIR) && $(UV) run dbt run --select gold && $(UV) run dbt test --select gold

test-gold: ## [6/7] Run Gold-layer SQL tests
	@echo "------------------------------------------------------------"
	@echo " STEP 6 / 7  -  GOLD SQL TESTS"
	@echo "------------------------------------------------------------"
	$(PYTHON) scripts/sql_test.py tests/gold

gx-tests: ## [7/7] Run Great Expectations across Bronze/Silver/Gold
	@echo "------------------------------------------------------------"
	@echo " STEP 7 / 7  -  GREAT EXPECTATIONS TESTS (Bronze, Silver, Gold)"
	@echo "------------------------------------------------------------"
	$(PYTHON) -m pipeline.data_quality.run --layer all

data-pipeline: preflight extract test-bronze dbt-silver test-silver dbt-gold test-gold gx-tests ## Run the full 8-stage data pipeline in strict order
	@echo ""
	@echo "$(GREEN)$(BOLD)PIPELINE COMPLETE$(RESET) — all 8 stages passed."

# ---- Composite production gate ----------------------------------------
all: ci data-pipeline ## Full production gate: static checks + unit tests + the live 8-stage data pipeline

# ---- Build / Release --------------------------------------------------------
build: ## Build a distributable wheel; also builds a Docker image if a Dockerfile exists
	$(UV) build
	@if [ -f Dockerfile ]; then \
		echo "$(BOLD)>> Building Docker image walmart-pipeline:$(VERSION)$(RESET)"; \
		docker build -t walmart-pipeline:$(VERSION) . ; \
	else \
		echo "$(YELLOW)No Dockerfile found — skipping image build.$(RESET)"; \
	fi

# ---- Housekeeping -----------------------------------------------------------
clean: ## Remove caches and generated artifacts (keeps the venv)
	rm -rf .pytest_cache .ruff_cache .mypy_cache
	find . -type d -name "__pycache__" -exec rm -rf {} +
	rm -rf $(DBT_DIR)/target $(DBT_DIR)/logs $(DBT_DIR)/dbt_packages
	rm -rf gx/uncommitted/data_docs

clean-venv: ## Remove the virtual environment entirely (forces a full uv sync next run)
	rm -rf .venv
	@echo "$(YELLOW)Note: on Windows, a locked .venv (e.g. an active dbt shell or VS Code kernel) may need that process closed first, or an elevated terminal.$(RESET)"