"""
sync_gold_to_databricks.py
===========================
Incrementally syncs Postgres ``gold`` tables into Databricks
(catalog/schema from ``DATABRICKS_CATALOG`` / ``DATABRICKS_SCHEMA`` in .env).

Per table:
1. Read column names/types from Postgres information_schema.
2. CREATE TABLE IF NOT EXISTS in Databricks (Delta). Never alters existing tables.
3. Read the current watermark from Databricks (MAX(updated_timestamp), or
   MAX(gold_loaded_at) for the 3 tables without an updated_timestamp).
4. Pull only Postgres rows newer than that watermark (all rows if empty).
5. Upsert with a batched MERGE INTO.

Usage (from repo root):
    uv run python scripts/sync_gold_to_databricks.py
    uv run python scripts/sync_gold_to_databricks.py --only dim_brands dim_categories
    uv run python scripts/sync_gold_to_databricks.py --full-refresh
    uv run python scripts/sync_gold_to_databricks.py --dry-run

Requires: databricks-sql-connector, polars

Known limitation: unconstrained Postgres ``numeric`` columns map to
DECIMAL(38,9) here -- widen this if your data needs more precision.
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from datetime import UTC, date, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

import polars as pl
from rich.console import Console
from rich.table import Table
from sqlalchemy import text

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from utils import engine as config
from utils.connection import (
    get_databricks_connection,
    get_postgres_engine,
)

console = Console()

BATCH_SIZE = 100  # rows per MERGE; keeps VALUES lists from getting too large


# ==============================================================
# Table configuration
# ==============================================================
# primary_key: column(s) used to match rows in the MERGE.
# watermark_col: column used to find new/changed rows. Usually
#   updated_timestamp; falls back to gold_loaded_at where that's missing.


@dataclass(frozen=True)
class TableSyncConfig:
    primary_key: tuple[str, ...]
    watermark_col: str


TABLES: dict[str, TableSyncConfig] = {
    "dim_brands": TableSyncConfig(("brand_id",), "gold_loaded_at"),
    "dim_categories": TableSyncConfig(("category_id",), "gold_loaded_at"),
    "dim_customers": TableSyncConfig(("customer_id",), "updated_timestamp"),
    "dim_payment_methods": TableSyncConfig(("payment_method_id",), "gold_loaded_at"),
    "dim_products": TableSyncConfig(("product_id",), "updated_timestamp"),
    "dim_stores": TableSyncConfig(("store_id",), "updated_timestamp"),
    "dim_orders": TableSyncConfig(("order_id",), "updated_timestamp"),
    "fact_order_items": TableSyncConfig(("order_item_id",), "updated_timestamp"),
}

# Postgres data_type -> Databricks SQL type.
_SIMPLE_TYPE_MAP = {
    "bigint": "BIGINT",
    "integer": "INT",
    "smallint": "SMALLINT",
    "text": "STRING",
    "character varying": "STRING",
    "character": "STRING",
    "boolean": "BOOLEAN",
    "double precision": "DOUBLE",
    "real": "FLOAT",
    "date": "DATE",
    "timestamp with time zone": "TIMESTAMP",
    # Needs Databricks Runtime 13.3+ / Unity Catalog. Older warehouse?
    # Use "TIMESTAMP" instead (loses the with/without-tz distinction).
    "timestamp without time zone": "TIMESTAMP_NTZ",
}


@dataclass(frozen=True)
class ColumnInfo:
    name: str
    pg_data_type: str
    numeric_precision: int | None
    numeric_scale: int | None

    @property
    def databricks_type(self) -> str:
        if self.pg_data_type == "numeric":
            precision = min(self.numeric_precision or 38, 38)
            scale = self.numeric_scale if self.numeric_scale is not None else 9
            scale = min(scale, precision)
            return f"DECIMAL({precision},{scale})"
        try:
            return _SIMPLE_TYPE_MAP[self.pg_data_type]
        except KeyError as error:
            raise ValueError(
                f"No Databricks type mapping for Postgres type "
                f"'{self.pg_data_type}' (column '{self.name}') -- add one "
                f"to _SIMPLE_TYPE_MAP."
            ) from error


# ==============================================================
# Postgres introspection + extraction
# ==============================================================


def fetch_columns(pg_engine, schema: str, table: str) -> list[ColumnInfo]:
    """Get a Postgres table's columns, in order."""
    query = text(
        """
        SELECT column_name, data_type, numeric_precision, numeric_scale
        FROM information_schema.columns
        WHERE table_schema = :schema AND table_name = :table
        ORDER BY ordinal_position
        """
    )
    with pg_engine.connect() as conn:
        rows = conn.execute(query, {"schema": schema, "table": table}).mappings().all()
    if not rows:
        raise ValueError(
            f"No columns found for {schema}.{table} -- does the table exist?"
        )
    return [
        ColumnInfo(
            name=row["column_name"],
            pg_data_type=row["data_type"],
            numeric_precision=row["numeric_precision"],
            numeric_scale=row["numeric_scale"],
        )
        for row in rows
    ]


def extract_incremental_rows(
    pg_engine,
    pg_schema: str,
    table: str,
    columns: list[ColumnInfo],
    watermark_col: str,
    last_watermark: datetime | None,
) -> pl.DataFrame:
    """Pull rows newer than last_watermark (all rows if None)."""
    col_list = ", ".join(col.name for col in columns)
    # last_watermark comes from Databricks, not user input, so it's safe to inline.
    where_clause = (
        f"WHERE {watermark_col} > '{last_watermark.isoformat(sep=' ')}'"
        if last_watermark is not None
        else ""
    )
    query = f"SELECT {col_list} FROM {pg_schema}.{table} {where_clause}"
    with pg_engine.connect() as conn:
        return pl.read_database(query, conn)


# ==============================================================
# Databricks DDL, watermark, and upsert
# ==============================================================


def ensure_table_exists(
    dbx_conn, catalog: str, schema: str, table: str, columns: list[ColumnInfo]
) -> None:
    column_defs = ",\n    ".join(f"{col.name} {col.databricks_type}" for col in columns)
    ddl = f"""
        CREATE TABLE IF NOT EXISTS {catalog}.{schema}.{table} (
            {column_defs}
        )
        USING DELTA
    """
    with dbx_conn.cursor() as cursor:
        cursor.execute(ddl)


def fetch_current_watermark(
    dbx_conn, catalog: str, schema: str, table: str, watermark_col: str
) -> Any | None:
    """Current MAX(watermark_col) in Databricks, or None if table is empty/new."""
    query = f"SELECT MAX({watermark_col}) FROM {catalog}.{schema}.{table}"
    with dbx_conn.cursor() as cursor:
        cursor.execute(query)
        row = cursor.fetchone()
    return row[0] if row else None


def _sql_literal(value: Any) -> str:
    """Format a Python value as a Databricks SQL literal."""
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, (int, float, Decimal)):
        return str(value)
    if isinstance(value, datetime):
        if value.tzinfo is not None:
            # TIMESTAMP'...' string literals aren't reliable for tz-aware
            # values in Databricks. Use an exact epoch-micros int instead.
            epoch = datetime(1970, 1, 1, tzinfo=UTC)
            delta = value.astimezone(UTC) - epoch
            epoch_micros = (
                delta.days * 86_400_000_000
                + delta.seconds * 1_000_000
                + delta.microseconds
            )
            return f"TIMESTAMP_MICROS({epoch_micros})"
        return f"TIMESTAMP'{value.isoformat(sep=' ')}'"
    if isinstance(value, date):
        return f"DATE'{value.isoformat()}'"
    escaped = str(value).replace("'", "''")
    return f"'{escaped}'"


def upsert_rows(
    dbx_conn,
    catalog: str,
    schema: str,
    table: str,
    columns: list[ColumnInfo],
    primary_key: tuple[str, ...],
    rows: list[dict[str, Any]],
    dry_run: bool,
) -> None:
    col_names = [col.name for col in columns]
    col_list = ", ".join(col_names)
    non_key_cols = [c for c in col_names if c not in primary_key]
    on_clause = " AND ".join(f"t.{pk} = s.{pk}" for pk in primary_key)
    insert_vals = ", ".join(f"s.{c}" for c in col_names)

    with dbx_conn.cursor() as cursor:
        for start in range(0, len(rows), BATCH_SIZE):
            batch = rows[start : start + BATCH_SIZE]
            values_sql = ",\n".join(
                "(" + ", ".join(_sql_literal(row[c]) for c in col_names) + ")"
                for row in batch
            )
            # Databricks rejects "USING (VALUES ...) AS s(col1, col2)" in a
            # MERGE -- column aliases aren't allowed on the USING source
            # directly. Wrapping the VALUES in a SELECT sidesteps that: the
            # inner alias (a plain FROM clause) is fine, and the outer alias
            # has no column list.
            source_sql = (
                f"(SELECT {col_list} FROM (VALUES {values_sql}) AS v({col_list})) AS s"
            )
            statement_parts = [
                f"MERGE INTO {catalog}.{schema}.{table} AS t",
                f"USING {source_sql}",
                f"ON {on_clause}",
            ]
            if non_key_cols:
                update_clause = ", ".join(f"t.{c} = s.{c}" for c in non_key_cols)
                statement_parts.append(f"WHEN MATCHED THEN UPDATE SET {update_clause}")
            statement_parts.append(
                f"WHEN NOT MATCHED THEN INSERT ({col_list}) VALUES ({insert_vals})"
            )
            merge_sql = "\n".join(statement_parts)

            if dry_run:
                console.print(f"[dim]-- {table}: would execute --[/dim]\n{merge_sql}\n")
                continue
            cursor.execute(merge_sql)


# ==============================================================
# Per-table orchestration
# ==============================================================


@dataclass
class SyncOutcome:
    table: str
    status: str  # "SYNCED", "NO CHANGE", "FAILED"
    detail: str


def sync_table(
    pg_engine,
    dbx_conn,
    table: str,
    cfg: TableSyncConfig,
    pg_schema: str,
    catalog: str,
    dbx_schema: str,
    full_refresh: bool,
    dry_run: bool,
) -> SyncOutcome:
    columns = fetch_columns(pg_engine, pg_schema, table)
    column_names = {col.name for col in columns}

    missing_pk = set(cfg.primary_key) - column_names
    if missing_pk:
        raise ValueError(f"primary key column(s) not found: {', '.join(missing_pk)}")
    if cfg.watermark_col not in column_names:
        raise ValueError(f"watermark column '{cfg.watermark_col}' not found")

    ensure_table_exists(dbx_conn, catalog, dbx_schema, table, columns)

    last_watermark = (
        None
        if full_refresh
        else fetch_current_watermark(
            dbx_conn, catalog, dbx_schema, table, cfg.watermark_col
        )
    )

    df = extract_incremental_rows(
        pg_engine, pg_schema, table, columns, cfg.watermark_col, last_watermark
    )

    if df.is_empty():
        return SyncOutcome(table, "NO CHANGE", "no new or changed rows")

    upsert_rows(
        dbx_conn,
        catalog,
        dbx_schema,
        table,
        columns,
        cfg.primary_key,
        df.rows(named=True),
        dry_run,
    )
    suffix = " (dry run)" if dry_run else ""
    return SyncOutcome(table, "SYNCED", f"{df.height} row(s) upserted{suffix}")


def render_summary(outcomes: list[SyncOutcome]) -> None:
    styles = {"SYNCED": "green", "NO CHANGE": "dim", "FAILED": "red"}
    result_table = Table(title="Gold -> Databricks sync", show_lines=True)
    result_table.add_column("Table", style="bold cyan", no_wrap=True)
    result_table.add_column("Status", justify="center", no_wrap=True)
    result_table.add_column("Detail")
    for outcome in outcomes:
        result_table.add_row(
            outcome.table,
            f"[{styles[outcome.status]}]{outcome.status}[/]",
            outcome.detail,
        )
    console.print(result_table)


def _short_error(error: Exception, limit: int = 300) -> str:
    """One-line summary for the results table (full error is printed above it)."""
    text = " ".join(str(error).split())  # collapse whitespace
    if len(text) > limit:
        text = text[:limit] + "..."
    return f"{type(error).__name__}: {text}"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Incrementally sync Postgres gold tables into Databricks."
    )
    parser.add_argument(
        "--only",
        nargs="*",
        metavar="TABLE",
        help="Only sync these tables (default: all).",
    )
    parser.add_argument(
        "--full-refresh",
        action="store_true",
        help="Ignore the current watermark and re-pull full history for the selected tables.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the MERGE statements instead of executing them.",
    )
    args = parser.parse_args()

    tables_to_sync = args.only or list(TABLES.keys())
    unknown = [t for t in tables_to_sync if t not in TABLES]
    if unknown:
        console.print(f"[red]Unknown table(s): {', '.join(unknown)}[/red]")
        console.print(f"Known tables: {', '.join(TABLES)}")
        return 1

    pg_schema = config.POSTGRES_SCHEMA_GOLD
    catalog = config.DATABRICKS_CATALOG
    dbx_schema = config.DATABRICKS_SCHEMA
    if not pg_schema:
        console.print("[red]POSTGRES_SCHEMA_GOLD is not set in .env[/red]")
        return 1
    if not catalog or not dbx_schema:
        console.print(
            "[red]DATABRICKS_CATALOG / DATABRICKS_SCHEMA is not set in .env[/red]"
        )
        return 1

    pg_engine = get_postgres_engine()
    dbx_conn = get_databricks_connection()

    outcomes: list[SyncOutcome] = []
    for table in tables_to_sync:
        cfg = TABLES[table]
        try:
            outcomes.append(
                sync_table(
                    pg_engine,
                    dbx_conn,
                    table,
                    cfg,
                    pg_schema,
                    catalog,
                    dbx_schema,
                    full_refresh=args.full_refresh,
                    dry_run=args.dry_run,
                )
            )
        except Exception as error:  # noqa: BLE001 - report and continue with other tables
            # Print the full error here, above the summary table, so it's not
            # buried/truncated inside a Rich table cell.
            console.print(f"\n[bold red]{table} failed[/bold red] -- full error below:")
            console.print(str(error))
            outcomes.append(SyncOutcome(table, "FAILED", _short_error(error)))

    render_summary(outcomes)
    return 1 if any(outcome.status == "FAILED" for outcome in outcomes) else 0


if __name__ == "__main__":
    raise SystemExit(main())
