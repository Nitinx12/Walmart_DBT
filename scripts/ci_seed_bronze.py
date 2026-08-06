"""
scripts/ci_seed_bronze.py
==========================
CI-only fixture loader for the bronze layer. Writes sample rows straight
into POSTGRES_SCHEMA_BRONZE, bypassing MongoDB/PySpark entirely, so the
`integration` CI job can exercise the real medallion gate (bronze checks ->
dbt silver -> dbt gold) against a plain Postgres service container.

Deliberately mirrors extract.py's actual write shape rather than
reinventing it:
  - `_id` is a text column and the table's primary key, same as
    sanitize_for_postgres() casting Mongo's ObjectId to string.
  - nested/array values get JSON-serialized here if the fixture didn't
    already do it -- same effect as extract.py's F.to_json() step.
  - every other column keeps whatever type pandas infers from the JSON
    fixture -- same spirit as "Spark infers it, nothing is renamed or
    cast" in extract.py. In particular: DO NOT put real datetime objects
    in a fixture's watermark-looking fields (updated_at, created_at, ...)
    -- extract.py's own docstring notes these are plain strings in Mongo,
    not BSON dates, so fixtures should use the same
    "YYYY-MM-DD HH:MM:SS" string format, not a JSON date type (JSON has
    none anyway, but don't reach for an ISO-with-timezone string either).
  - control tables (etl_watermarks, etl_logs) use the same DDL as
    extract.py's ensure_control_tables(), seeded with one OK row per
    collection, since the bronze SQL checks may inspect them.

NOT reproduced: watermark-based incremental logic, the real MERGE
(ON CONFLICT) path, Spark's exact type inference. CI only needs the
*shape* bronze leaves behind for silver/gold to build against, not a
byte-identical replica of a live extract.py run.

Fixtures: tests/fixtures/bronze/<collection>.json -- a JSON array of
objects, one file per collection extract.py would normally create.
Nothing here is hardcoded to a fixed collection list -- add a new fixture
file to seed a new collection.

Usage:
    uv run python scripts/ci_seed_bronze.py
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import pandas as pd
from sqlalchemy import text

from utils.connection import get_postgres_engine
from utils.logger import get_logger

log = get_logger("ci_seed_bronze")

PROJECT_ROOT = Path(__file__).resolve().parent.parent
FIXTURE_DIR = PROJECT_ROOT / "tests" / "fixtures" / "bronze"

# Same default-fallback pattern as extract.py's POSTGRES_SCHEMA constant.
POSTGRES_SCHEMA_BRONZE = os.getenv("POSTGRES_SCHEMA_BRONZE", "bronze")

PRIMARY_KEY_COLUMN = "_id"
WATERMARK_TABLE = "etl_watermarks"
LOG_TABLE = "etl_logs"


def ensure_schema(engine, schema: str) -> None:
    with engine.begin() as conn:
        conn.execute(text(f'CREATE SCHEMA IF NOT EXISTS "{schema}"'))


def ensure_control_tables(engine, schema: str) -> None:
    """Same DDL as extract.py's ensure_control_tables() -- duplicated here
    rather than imported, so this script doesn't need to import extract.py's
    pyspark/rich/mongo dependencies just for two CREATE TABLE statements."""
    ddl_watermarks = f"""
        CREATE TABLE IF NOT EXISTS {schema}.{WATERMARK_TABLE} (
            table_name              TEXT PRIMARY KEY,
            incremental_column       TEXT,
            last_watermark_value     TIMESTAMPTZ,
            last_run_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
            last_run_mode            TEXT,
            last_run_rows_inserted   BIGINT NOT NULL DEFAULT 0,
            last_run_rows_updated    BIGINT NOT NULL DEFAULT 0,
            updated_at               TIMESTAMPTZ NOT NULL DEFAULT now()
        )
    """
    ddl_logs = f"""
        CREATE TABLE IF NOT EXISTS {schema}.{LOG_TABLE} (
            id                      BIGSERIAL PRIMARY KEY,
            run_id                  TEXT NOT NULL,
            table_name              TEXT NOT NULL,
            mode                    TEXT,
            incremental_column      TEXT,
            status                  TEXT NOT NULL,
            mongo_rows              BIGINT,
            postgres_rows_before    BIGINT,
            batch_rows              BIGINT,
            rows_inserted           BIGINT,
            rows_updated            BIGINT,
            skipped_rows            BIGINT,
            postgres_rows_after     BIGINT,
            columns_count           INT,
            validation_status       TEXT,
            validation_detail       TEXT,
            error                   TEXT,
            started_at              TIMESTAMPTZ,
            finished_at             TIMESTAMPTZ,
            duration_seconds        DOUBLE PRECISION,
            logged_at               TIMESTAMPTZ NOT NULL DEFAULT now()
        )
    """
    with engine.begin() as conn:
        conn.execute(text(ddl_watermarks))
        conn.execute(text(ddl_logs))


def seed_control_rows(engine, schema: str, table_name: str, row_count: int, col_count: int) -> None:
    """One OK watermark row + one OK log row per collection, mirroring what
    a real successful extract.py run leaves behind."""
    with engine.begin() as conn:
        conn.execute(
            text(f"""
                INSERT INTO {schema}.{WATERMARK_TABLE}
                    (table_name, incremental_column, last_watermark_value,
                     last_run_mode, last_run_rows_inserted, last_run_rows_updated)
                VALUES (:table, NULL, NULL, 'full', :rows, 0)
                ON CONFLICT (table_name) DO UPDATE SET
                    last_run_at = now(), updated_at = now(),
                    last_run_rows_inserted = EXCLUDED.last_run_rows_inserted
            """),
            {"table": table_name, "rows": row_count},
        )
        conn.execute(
            text(f"""
                INSERT INTO {schema}.{LOG_TABLE}
                    (run_id, table_name, mode, status, mongo_rows,
                     postgres_rows_before, batch_rows, rows_inserted, rows_updated,
                     skipped_rows, postgres_rows_after, columns_count,
                     validation_status, validation_detail, started_at, finished_at,
                     duration_seconds)
                VALUES
                    ('ci_seed', :table, 'full', 'OK', :rows, 0, :rows, :rows, 0,
                     0, :rows, :cols, 'PASS', 'ci fixture seed', now(), now(), 0)
            """),
            {"table": table_name, "rows": row_count, "cols": col_count},
        )


def seed_collection(engine, schema: str, fixture_path: Path) -> tuple[int, int]:
    collection = fixture_path.stem
    rows = json.loads(fixture_path.read_text())
    if not rows:
        log.warning(f"[{collection}] fixture file is empty, skipping")
        return 0, 0

    df = pd.DataFrame(rows)

    if PRIMARY_KEY_COLUMN not in df.columns:
        raise ValueError(
            f'[{collection}] fixture has no "{PRIMARY_KEY_COLUMN}" field -- every '
            f"bronze table needs one, same as extract.py's PRIMARY_KEY_COLUMN"
        )
    df[PRIMARY_KEY_COLUMN] = df[PRIMARY_KEY_COLUMN].astype(str)

    # Anything still a dict/list in the fixture (i.e. wasn't already
    # pre-stringified) gets JSON-serialized here -- same effect as
    # sanitize_for_postgres()'s F.to_json() step.
    for col in df.columns:
        if df[col].apply(lambda v: isinstance(v, (dict, list))).any():
            df[col] = df[col].apply(lambda v: json.dumps(v) if isinstance(v, (dict, list)) else v)

    df.to_sql(collection, engine, schema=schema, if_exists="replace", index=False)

    with engine.begin() as conn:
        conn.execute(text(
            f'ALTER TABLE "{schema}"."{collection}" ADD PRIMARY KEY ("{PRIMARY_KEY_COLUMN}")'
        ))

    log.info(f"[{collection}] seeded {len(df)} row(s), {len(df.columns)} column(s)")
    return len(df), len(df.columns)


def main() -> int:
    if not FIXTURE_DIR.exists():
        log.error(f"Fixture directory not found: {FIXTURE_DIR}")
        return 1

    fixture_files = sorted(FIXTURE_DIR.glob("*.json"))
    if not fixture_files:
        log.error(f"No fixture files found in {FIXTURE_DIR}")
        return 1

    engine = get_postgres_engine()

    ensure_schema(engine, POSTGRES_SCHEMA_BRONZE)
    ensure_control_tables(engine, POSTGRES_SCHEMA_BRONZE)

    for fixture_path in fixture_files:
        try:
            row_count, col_count = seed_collection(engine, POSTGRES_SCHEMA_BRONZE, fixture_path)
            seed_control_rows(engine, POSTGRES_SCHEMA_BRONZE, fixture_path.stem, row_count, col_count)
        except Exception:
            log.exception(f"Failed to seed {fixture_path.name}")
            return 1

    log.info(f"Seeded {len(fixture_files)} bronze table(s) from {FIXTURE_DIR}")
    return 0


if __name__ == "__main__":
    sys.exit(main())