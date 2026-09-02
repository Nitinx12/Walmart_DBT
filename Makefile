# Load environment variables from .env if it exists
ifneq (,$(wildcard ./.env))
    include .env
    export
endif

# Set global environment variables
export PYTHONPATH = $(PWD)
export PYTHONIOENCODING = utf-8

# Declare phony targets to prevent conflicts with files of the same name
.PHONY: all preflight extract test-bronze dbt-silver test-silver dbt-gold test-gold gx-tests

# Master runner: executes the fixed eight-stage pipeline in strict order
all: preflight extract test-bronze dbt-silver test-silver dbt-gold test-gold gx-tests

preflight:
	@echo "------------------------------------------------------------"
	@echo " STEP 0 / 7  -  PREFLIGHT (dependency check)"
	@echo "------------------------------------------------------------"
	uv run python -c "import pyspark; assert pyspark.__version__.startswith('3.5'), f'Incompatible PySpark version: {pyspark.__version__}. Requires 3.5.x'"

extract:
	@echo "------------------------------------------------------------"
	@echo " STEP 1 / 7  -  EXTRACT (MongoDB to Bronze)"
	@echo "------------------------------------------------------------"
	uv run python scripts/extract.py

test-bronze:
	@echo "------------------------------------------------------------"
	@echo " STEP 2 / 7  -  BRONZE SQL TESTS"
	@echo "------------------------------------------------------------"
	uv run python scripts/sql_test.py tests/bronze

dbt-silver:
	@echo "------------------------------------------------------------"
	@echo " STEP 3 / 7  -  DBT SILVER (build and test)"
	@echo "------------------------------------------------------------"
	cd walmart_dbt && uv run dbt run --select silver
	cd walmart_dbt && uv run dbt test --select silver

test-silver:
	@echo "------------------------------------------------------------"
	@echo " STEP 4 / 7  -  SILVER SQL TESTS"
	@echo "------------------------------------------------------------"
	uv run python scripts/sql_test.py tests/silver

dbt-gold:
	@echo "------------------------------------------------------------"
	@echo " STEP 5 / 7  -  DBT GOLD (build and test)"
	@echo "------------------------------------------------------------"
	cd walmart_dbt && uv run dbt run --select gold
	cd walmart_dbt && uv run dbt test --select gold

test-gold:
	@echo "------------------------------------------------------------"
	@echo " STEP 6 / 7  -  GOLD SQL TESTS"
	@echo "------------------------------------------------------------"
	uv run python scripts/sql_test.py tests/gold

gx-tests:
	@echo "------------------------------------------------------------"
	@echo " STEP 7 / 7  -  GREAT EXPECTATIONS TESTS (Bronze, Silver, Gold)"
	@echo "------------------------------------------------------------"
	uv run python -m pipeline.data_quality.run --layer all
