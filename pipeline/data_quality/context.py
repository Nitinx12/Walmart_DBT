"""
Great Expectations Data Context setup for the Walmart pipeline.

Builds (or reuses) a file-backed GX context, registers the Postgres
datasource, and registers one table asset per bronze table. Suite files
in `suites/` import `get_bronze_asset()` to attach expectations.

Connection details come from `utils.engine` (already validated at import
time -- see that module for the full list of required env vars) instead
of being re-read/guessed here. Previously this file built its own
Postgres connection string from `os.environ` directly, which (a) assumed
env var names that engine.py might not actually use, (b) silently
defaulted POSTGRES_PORT to "5432" instead of failing loudly like the
rest of the pipeline does, and (c) dropped the sslmode/channel_binding
query params that `utils.connection.get_postgres_engine()` adds for
managed providers like Neon -- so GX could end up talking to Postgres
differently than the rest of the pipeline. Building the connection
string the same way connection.py does removes that whole class of bug.

NOTE: this assumes `utils` is importable as a top-level package (i.e.
connection.py/engine.py/logger.py live in a `utils/` folder at the repo
root, per logger.py's own docstring). Adjust the `from utils import ...`
lines below if your actual package name/path differs.
"""

import logging
from functools import lru_cache

import great_expectations as gx
from great_expectations.data_context import AbstractDataContext
from sqlalchemy.engine import URL

from utils import engine as config
from utils.logger import get_logger

log = get_logger("data_quality.context", console_level=logging.WARNING)

# engine.py only warns (doesn't raise) if POSTGRES_SCHEMA_BRONZE is unset,
# since it's meant to be optional -- so fall back to "bronze" here rather
# than hard-coding it and silently ignoring the env var when it IS set.
BRONZE_SCHEMA = config.POSTGRES_SCHEMA_BRONZE or "bronze"

# Business tables only — etl_logs / etl_watermarks are pipeline metadata,
# not source data, so they're excluded from data-quality validation.
BRONZE_TABLES = [
    "customers",
    "employees",
    "order_items",
    "orders",
    "products",
    "stores",
]

# Silver adds three normalized dimension tables (brands, categories,
# payment_methods) that don't exist in bronze -- orders.payment_method and
# products.category were denormalized text in bronze; silver replaces them
# with payment_method_id / category_id (+ brand_id) foreign keys and these
# lookup tables.
#
# Unlike BRONZE_SCHEMA, we don't assume engine.py necessarily defines a
# POSTGRES_SCHEMA_SILVER constant (bronze's own docstring notes it might
# only warn for the bronze one) -- so this uses getattr with a default
# instead of a bare attribute access, to fail over to "silver" rather than
# raising AttributeError if that constant isn't there. Confirm the actual
# name in engine.py and switch to a bare attribute access (like
# BRONZE_SCHEMA above) if it does exist, so a typo'd env var fails loudly
# instead of silently falling back.
SILVER_SCHEMA = getattr(config, "POSTGRES_SCHEMA_SILVER", None) or "silver"

SILVER_TABLES = [
    "brands",
    "categories",
    "customers",
    "employees",
    "order_items",
    "orders",
    "payment_methods",
    "products",
    "stores",
]

# Gold is a star schema: dim_* tables (conformed dimensions) plus
# fact_order_items (the only fact table). Order-grain measures like
# total_amount live on dim_orders itself rather than a separate
# "fact_orders" table -- fact_order_items is the line-item grain.
#
# NOTE: there is no employees table anywhere in gold (no dim_employees),
# even though bronze and silver both carry it. Confirm that's an
# intentional exclusion from the published star schema before assuming
# this list is incomplete rather than the source schema being what it is.
#
# Same getattr-with-default reasoning as SILVER_SCHEMA above: don't
# assume engine.py necessarily defines POSTGRES_SCHEMA_GOLD.
GOLD_SCHEMA = getattr(config, "POSTGRES_SCHEMA_GOLD", None) or "gold"

GOLD_TABLES = [
    "dim_brands",
    "dim_categories",
    "dim_customers",
    "dim_orders",
    "dim_payment_methods",
    "dim_products",
    "dim_stores",
    "fact_order_items",
]


def _connection_string() -> str:
    """Build the Postgres connection string the same way
    utils.connection.get_postgres_engine() does, so GX and the rest of
    the pipeline never disagree about how to reach the database."""
    query = {
        k: v
        for k, v in {
            "sslmode": getattr(config, "POSTGRES_SSLMODE", None),
            "channel_binding": getattr(config, "POSTGRES_CHANNEL_BINDING", None),
        }.items()
        if v
    }
    url = URL.create(
        "postgresql+psycopg2",
        username=config.POSTGRES_USERNAME,
        password=config.POSTGRES_PASSWORD,
        host=config.POSTGRES_HOST,
        port=config.POSTGRES_PORT,
        database=config.POSTGRES_DATABASE,
        query=query,
    )
    return url.render_as_string(hide_password=False)


@lru_cache(maxsize=1)
def get_context() -> AbstractDataContext:
    """Return the (cached) file-backed GX Data Context, creating it on first call."""
    log.info("Loading GX file-backed context")
    context = gx.get_context(mode="file")

    if "walmart_postgres" not in context.data_sources.all():
        log.info("Registering 'walmart_postgres' datasource")
        try:
            data_source = context.data_sources.add_postgres(
                "walmart_postgres", connection_string=_connection_string()
            )
        except Exception:
            log.exception("Failed to register 'walmart_postgres' datasource")
            raise
    else:
        data_source = context.data_sources.get("walmart_postgres")
        # Keep persisted asset definitions, but honour the current process's
        # .env values (especially host.docker.internal in container runners).
        data_source.connection_string = _connection_string()

    existing_assets = {a.name for a in data_source.assets}
    # Both layers share one Postgres datasource -- they're different
    # schemas in the same database -- so register bronze_<table> and
    # silver_<table> assets side by side rather than needing two contexts.
    for prefix, schema_name, tables in (
        ("bronze", BRONZE_SCHEMA, BRONZE_TABLES),
        ("silver", SILVER_SCHEMA, SILVER_TABLES),
        ("gold", GOLD_SCHEMA, GOLD_TABLES),
    ):
        for table_name in tables:
            asset_name = f"{prefix}_{table_name}"
            if asset_name not in existing_assets:
                log.info(f"Registering table asset '{asset_name}' (schema={schema_name})")
                data_source.add_table_asset(
                    name=asset_name, table_name=table_name, schema_name=schema_name
                )

    return context


def get_bronze_asset(table_name: str):
    """Look up a registered bronze table asset by its bare table name (e.g. 'orders')."""
    context = get_context()
    data_source = context.data_sources.get("walmart_postgres")
    return data_source.get_asset(f"bronze_{table_name}")


def get_silver_asset(table_name: str):
    """Look up a registered silver table asset by its bare table name (e.g. 'orders')."""
    context = get_context()
    data_source = context.data_sources.get("walmart_postgres")
    return data_source.get_asset(f"silver_{table_name}")


def get_gold_asset(table_name: str):
    """Look up a registered gold table asset by its bare table name (e.g. 'dim_orders')."""
    context = get_context()
    data_source = context.data_sources.get("walmart_postgres")
    return data_source.get_asset(f"gold_{table_name}")
