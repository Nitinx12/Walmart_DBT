"""
scripts/seed_demo_db.py

One-off utility: copy the gold schema from this project's local Postgres
into a separate, public demo Postgres (e.g. a free Neon or Supabase
project), scrubbing customer PII along the way.

This is NOT part of the regular pipeline — it exists purely to populate a
safe, public database for the hosted Streamlit dashboard demo, so the
real local/dev database never needs to be reachable from the internet.

Usage:
    uv run python scripts/seed_demo_db.py "postgresql://user:pass@host/dbname"

The target database must already exist (e.g. a fresh Neon project);
this script creates the schema and tables inside it.
"""

import argparse
import sys
from pathlib import Path

# scripts/seed_demo_db.py -> repo root is one level up. Put it on sys.path
# so `from utils....` resolves when this is run directly
# (`python scripts/seed_demo_db.py`), which only puts `scripts/` itself on
# sys.path, not the repo root — same fix as dashboard/app.py.
PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

import pandas as pd
from sqlalchemy import create_engine, text

from utils import engine as config
from utils.connection import get_postgres_engine
from utils.logger import get_logger

log = get_logger("seed_demo_db")

SOURCE_SCHEMA = config.POSTGRES_SCHEMA_GOLD

# Order is cosmetic — no FK constraints are created on the target — but
# dimensions-before-facts keeps things readable if you inspect it manually.
TABLES = [
    "dim_brands",
    "dim_categories",
    "dim_payment_methods",
    "dim_products",
    "dim_stores",
    "dim_customers",
    "dim_orders",
    "fact_order_items",
]


def anonymize_customers(df: pd.DataFrame) -> pd.DataFrame:
    """Replace real customer PII with deterministic placeholders keyed off
    customer_id, so joins/aggregations behave identically — only the
    identifying text changes. Never point a public demo at real names,
    emails, or phone numbers."""
    df = df.copy()
    if "customer_name" in df.columns:
        df["customer_name"] = "Customer " + df["customer_id"].astype(str)
    if "email" in df.columns:
        df["email"] = "customer" + df["customer_id"].astype(str) + "@example.com"
    if "phone" in df.columns:
        df["phone"] = "555-0100"
    if "phone_extension" in df.columns:
        df["phone_extension"] = None
    return df


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "target_url", help="SQLAlchemy connection string for the demo Postgres"
    )
    parser.add_argument(
        "--schema",
        default="gold",
        help="Schema name to create/use on the TARGET database (default: gold)",
    )
    args = parser.parse_args()

    source = get_postgres_engine()
    target = create_engine(args.target_url)

    with target.connect() as conn:
        conn.execute(text(f"CREATE SCHEMA IF NOT EXISTS {args.schema}"))
        conn.commit()

    for table in TABLES:
        log.info(f"Copying {SOURCE_SCHEMA}.{table} -> {args.schema}.{table}")
        df = pd.read_sql(f"SELECT * FROM {SOURCE_SCHEMA}.{table}", source)

        if table == "dim_customers":
            df = anonymize_customers(df)

        df.to_sql(table, target, schema=args.schema, if_exists="replace", index=False)
        log.info(f"  {len(df):,} rows written")

    log.info("Demo database seeded successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
