# Great Expectations data quality

This project uses [Great Expectations (GX)](https://greatexpectations.io/) to
validate the tables in the Bronze, Silver, and Gold PostgreSQL schemas. GX is
an additional, on-demand data-quality check. It does **not** replace the dbt
tests or the standalone SQL checks that are part of the seven-stage pipeline.

## What GX validates

GX connects to the shared `walmart_postgres` datasource and validates complete
tables. The suites currently check column requirements such as non-null values,
unique identifiers, non-negative numeric measures, and the shape of customer
email addresses.

| Layer | Tables | Suite count |
|---|---|---:|
| Bronze | `customers`, `employees`, `orders`, `order_items`, `products`, `stores` | 6 |
| Silver | `brands`, `categories`, `payment_methods`, `customers`, `employees`, `orders`, `order_items`, `products`, `stores` | 9 |
| Gold | `dim_brands`, `dim_categories`, `dim_payment_methods`, `dim_customers`, `dim_stores`, `dim_products`, `dim_orders`, `fact_order_items` | 8 |

GX deliberately does not currently validate cross-table relationships or
formula checks such as `line_amount = quantity * unit_price`. Those checks
belong in dbt tests, the SQL test suite, or a future custom GX expectation.

## Before running

Run commands from the repository root, not from `pipeline/` or
`pipeline/data_quality/`:

```powershell
cd C:\Users\91852\OneDrive\Desktop\Git-Repo\walmart
uv sync
```

Your `.env` must contain the PostgreSQL settings used by `utils/engine.py`, and
the schemas and tables being checked must already exist.

### Required compatibility fix

GX 1.21 returns datasource names when `context.data_sources.all()` is iterated.
Before the first run, ensure [`pipeline/data_quality/context.py`](../pipeline/data_quality/context.py)
contains this condition in `get_context()`:

```python
if "walmart_postgres" not in context.data_sources.all():
```

Do not use the older form that accesses `ds.name`; it raises
`AttributeError: 'str' object has no attribute 'name'`.

## Commands

All commands use the module form so that `pipeline` and `utils` are importable.

```powershell
# Run every GX suite in Bronze -> Silver -> Gold order.
uv run python -m pipeline.data_quality.run --layer all

# The same command; --layer all is the default.
uv run python -m pipeline.data_quality.run

# Run one layer only.
uv run python -m pipeline.data_quality.run --layer bronze
uv run python -m pipeline.data_quality.run --layer silver
uv run python -m pipeline.data_quality.run --layer gold

# Stop as soon as a layer fails or cannot run.
uv run python -m pipeline.data_quality.run --layer all --fail-fast

# Show supported options without contacting the database.
uv run python -m pipeline.data_quality.run --help
```

The all-layer command continues after a failed layer by default, so one run
reports the health of all three layers. It exits with `0` when every check
passes, `1` when one or more expectations fail, and `2` when a layer cannot
run (for example, because of a connection, schema, or configuration error).

## How a run works

1. `run.py` selects the requested layer functions in Bronze, Silver, Gold
   order.
2. Each suite module builds or updates its `ExpectationSuite` and
   `ValidationDefinition`; repeat runs reconcile the stored objects instead of
   creating duplicates.
3. The runner builds or updates one checkpoint for the layer, then runs it
   against the whole table batches.
4. It prints a pass/fail result for every table and returns a meaningful exit
   code for shells and orchestrators.

The current Windows runner and Airflow DAG do not invoke GX. Run the command
above as a separate quality check until GX is intentionally added as a pipeline
stage; doing so would require updating both runners under the pipeline-stage
rule.

## File map

### Python implementation

| File | Purpose |
|---|---|
| [`pipeline/data_quality/run.py`](../pipeline/data_quality/run.py) | CLI runner, layer selection, checkpoints, results, and exit codes. |
| [`pipeline/data_quality/context.py`](../pipeline/data_quality/context.py) | File-backed GX context, Postgres datasource, and table-asset registration. |
| [`pipeline/data_quality/suites/bronze_suites.py`](../pipeline/data_quality/suites/bronze_suites.py) | Six Bronze suite definitions. |
| [`pipeline/data_quality/suites/silver_suites.py`](../pipeline/data_quality/suites/silver_suites.py) | Nine Silver suite definitions. |
| [`pipeline/data_quality/suites/gold_suites.py`](../pipeline/data_quality/suites/gold_suites.py) | Eight Gold suite definitions. |
| `pipeline/data_quality/__init__.py`, `pipeline/data_quality/suites/__init__.py` | Package markers that make module execution and imports work. |
| [`utils/engine.py`](../utils/engine.py) | Validates and exposes environment configuration used for the GX connection. |
| [`utils/logger.py`](../utils/logger.py) | Provides the runner and suite loggers. |
| [`pyproject.toml`](../pyproject.toml), [`uv.lock`](../uv.lock) | Declare and lock `great-expectations` 1.21.0. |

### GX context and generated artifacts

| Path | Contents |
|---|---|
| [`gx/great_expectations.yml`](../gx/great_expectations.yml) | File-backed GX context, `walmart_postgres` datasource, stores, and local Data Docs configuration. |
| `gx/expectations/bronze_<table>_suite.json` | Six persisted Bronze expectation suites. |
| `gx/expectations/silver_<table>_suite.json` | Nine persisted Silver expectation suites. |
| `gx/expectations/gold_<table>_suite.json` | Eight persisted Gold expectation suites. |
| `gx/validation_definitions/{customers,employees,orders,order_items,products,stores}_validation.json` | Bronze validation definitions. |
| `gx/validation_definitions/silver_<table>_validation.json` | Nine Silver validation definitions. |
| `gx/validation_definitions/gold_<table>_validation.json` | Eight Gold validation definitions. |
| `gx/checkpoints/bronze_checkpoint.json`, `silver_checkpoint.json`, `gold_checkpoint.json` | One persisted checkpoint per layer. |
| `gx/plugins/custom_data_docs/styles/data_docs_custom_styles.css` | Custom styling for locally generated GX Data Docs. |
| `gx/.gitignore` | Excludes local-only GX state, including `uncommitted/` validation output and Data Docs. |

The JSON artifacts are created or updated by the runner. Keep them under
version control when expectation definitions change; do not commit the
generated `gx/uncommitted/` validation results or Data Docs output.

## Related quality checks

Run these separately when you need the project’s established pipeline-quality
coverage:

```powershell
# Standalone SQL checks
uv run python scripts/sql_test.py tests/bronze
uv run python scripts/sql_test.py tests/silver
uv run python scripts/sql_test.py tests/gold

# dbt schema tests
uv run dbt test --project-dir walmart_dbt --select silver
uv run dbt test --project-dir walmart_dbt --select gold
```

For the complete existing pipeline sequence, run:

```powershell
.\pipeline\run_pipeline.ps1
```
