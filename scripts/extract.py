"""
scripts/mongo_exp.py
=====================
Production-grade MongoDB -> PostgreSQL extraction script, built on PySpark.

WHAT IT DOES
------------
1. Auto-discovers every user collection in the configured Mongo database
   (no hardcoded collection list).
2. For each collection, loads it into Spark via the MongoDB Spark Connector
   and merges it into a same-named table in the configured Postgres schema
   (POSTGRES_SCHEMA_BRONZE in .env, "bronze" by default) via the JDBC
   driver in jars/postgresql.jar.
3. Incremental watermark column is auto-detected per collection (no single
   hardcoded name), checked in this priority order:
       updated_timestamp -> updated_at -> created_timestamp -> created_at
   The first one actually present on the collection's documents is used.
   Using an "updated" column when available (rather than only a "created"
   one) matters because documents that get modified after insert -- e.g. an
   order's status flipping to Cancelled -- must be re-synced, not just
   newly-inserted rows. If a collection has neither, it always does a full
   reload (no watermark tracking possible).
4. Rows are UPSERTED, not blindly appended: each document's Mongo `_id`
   is the merge key. New `_id`s are inserted, `_id`s already in Postgres
   have their row updated in place -- so status/field changes on existing
   records are correctly reflected instead of creating duplicate rows or
   being silently dropped. Mechanics: the incremental batch lands in a
   scratch staging table, then a single
   `INSERT ... ON CONFLICT ("_id") DO UPDATE` merges it into the real
   table, with `xmax = 0` used to split the result into exact
   inserted-vs-updated counts.
5. Watermark state lives in `<schema>.etl_watermarks` (one row per
   collection: which column was used, the last value seen, last run info).
   Per-collection run history lives in `<schema>.etl_logs` (one audit row
   per collection per run) -- both plain Postgres tables, queryable with
   any SQL client, in the same schema as the mirrored collections.
6. Column names/types are left exactly as Spark infers them from Mongo and
   as Spark's JDBC writer maps them into Postgres -- nothing is renamed or
   cast. The one unavoidable exception: Mongo's `_id` (ObjectId) and any
   nested struct/array/map fields are not representable as native Postgres
   scalar columns, so they are serialized to a string/JSON string so the
   write doesn't fail. This is logged clearly whenever it happens.
7. After each write, a post-load validation step re-counts the target
   table and confirms it matches what was expected (rows before + rows
   inserted -- updates don't change the row count) -- PASS/FAIL per table.
8. Prints a clean Rich report at the end: per-collection row counts,
   rows skipped / inserted / updated, validation result, current
   watermark state, and a run summary -- plus full detail in the daily
   log file via utils/logger.py and in `public.etl_logs`.

USAGE
-----
    uv run python scripts/mongo_exp.py
    uv run python scripts/mongo_exp.py --tables orders,customers
    uv run python scripts/mongo_exp.py --full-refresh
    uv run python scripts/mongo_exp.py --dry-run
    uv run python scripts/mongo_exp.py --watermark-column updated_timestamp

Requires (pyproject.toml): pyspark, pymongo, sqlalchemy, psycopg2-binary,
python-dotenv, rich. Also requires network access (first run) to fetch the
MongoDB Spark Connector via spark.jars.packages, and jars/postgresql.jar to
already exist on disk.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import traceback
import uuid
import warnings
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Optional

from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from rich.columns import Columns
from rich.progress import (
    Progress, SpinnerColumn, BarColumn, TextColumn, TimeElapsedColumn,
)
from rich import box

console = Console()


def _rich_showwarning(message, category, filename, lineno, file=None, line=None):
    """Route Python's stdlib `warnings` (e.g. the UserWarning utils/engine.py
    raises for unset optional env vars) through Rich instead of the default
    raw two-line stderr dump, so *every* line printed by this script goes
    through the same console."""
    console.print(f"[yellow]⚠ {category.__name__}:[/yellow] {message}")


warnings.showwarning = _rich_showwarning

# ---------------------------------------------------------------------------
# Make `utils` importable regardless of the CWD this script is launched from.
# ---------------------------------------------------------------------------
PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from utils import engine as config          # noqa: E402  (validated env vars)
from utils.connection import get_mongo_db    # noqa: E402
from utils.logger import get_logger          # noqa: E402

import pyspark                                            # noqa: E402
from pyspark.sql import SparkSession, DataFrame          # noqa: E402
from pyspark.sql import functions as F                    # noqa: E402
from pyspark.sql.types import StructType, ArrayType, MapType  # noqa: E402

from sqlalchemy import create_engine, text                # noqa: E402
from sqlalchemy.exc import SQLAlchemyError                 # noqa: E402

log = get_logger("mongo_exp")

# System / internal collections we never want to mirror into Postgres.
MONGO_SYSTEM_PREFIXES = ("system.",)

MONGO_CONNECTOR_PACKAGE = "org.mongodb.spark:mongo-spark-connector_2.12:10.4.0"
JDBC_JAR_PATH = PROJECT_ROOT / "jars" / "postgresql.jar"
JARS_DIR = PROJECT_ROOT / "jars"

# The mongo-spark-connector package above pulls in these 5 jars via Maven/Ivy
# every run. Download them once into JARS_DIR (filename must match exactly)
# and the script will use them directly via `spark.jars`, skipping Ivy
# resolution entirely -- no more ":: resolving dependencies ::" banner.
MONGO_CONNECTOR_JAR_URLS = {
    "mongo-spark-connector_2.12-10.4.0.jar":
        "https://repo1.maven.org/maven2/org/mongodb/spark/mongo-spark-connector_2.12/10.4.0/mongo-spark-connector_2.12-10.4.0.jar",
    "mongodb-driver-sync-5.1.4.jar":
        "https://repo1.maven.org/maven2/org/mongodb/mongodb-driver-sync/5.1.4/mongodb-driver-sync-5.1.4.jar",
    "bson-5.1.4.jar":
        "https://repo1.maven.org/maven2/org/mongodb/bson/5.1.4/bson-5.1.4.jar",
    "mongodb-driver-core-5.1.4.jar":
        "https://repo1.maven.org/maven2/org/mongodb/mongodb-driver-core/5.1.4/mongodb-driver-core-5.1.4.jar",
    "bson-record-codec-5.1.4.jar":
        "https://repo1.maven.org/maven2/org/mongodb/bson-record-codec/5.1.4/bson-record-codec-5.1.4.jar",
}

POSTGRES_SCHEMA = os.getenv("POSTGRES_SCHEMA_BRONZE", "bronze")
PRIMARY_KEY_COLUMN = "_id"

# Checked in this order per collection; first one actually present wins.
# "updated_*" is preferred over "created_*" because it also catches rows
# that were modified after insert, not just brand-new ones.
INCREMENTAL_COLUMN_CANDIDATES = ["updated_timestamp", "updated_at", "created_timestamp", "created_at"]

# Control tables (also live in POSTGRES_SCHEMA, alongside the mirrored
# collections). These are the source of truth for incremental state and run
# history -- deliberately plain tables so they can be queried with any SQL
# client, not just this script.
WATERMARK_TABLE = "etl_watermarks"
LOG_TABLE = "etl_logs"


# ---------------------------------------------------------------------------
# Result bookkeeping
# ---------------------------------------------------------------------------
@dataclass
class CollectionResult:
    name: str
    status: str = "OK"                    # OK | SKIPPED | FAILED | VALIDATION FAILED | DRY-RUN
    mode: str = "incremental"             # full | incremental | full (no watermark column)
    incremental_column: Optional[str] = None
    mongo_rows: int = 0
    postgres_rows_before: int = 0
    batch_rows: int = 0                   # rows pulled from Mongo this run
    rows_inserted: int = 0
    rows_updated: int = 0
    skipped_rows: int = 0
    postgres_rows_after: int = 0
    columns: int = 0
    error: Optional[str] = None          # short, single-line -- shown in the console table
    error_full: Optional[str] = None     # full traceback -- written to public.etl_logs only
    seconds: float = 0.0
    complex_fields_flattened: list = field(default_factory=list)
    watermark_before: Optional[datetime] = None
    watermark_after: Optional[datetime] = None
    validation_status: str = "N/A"
    validation_detail: str = ""


# ---------------------------------------------------------------------------
# Error message cleanup
# ---------------------------------------------------------------------------
def short_error(exc: BaseException, max_len: int = 220) -> str:
    """Collapse a possibly huge, multi-line Java/py4j/Python traceback into
    one clean, human-readable line for console display. Full detail is kept
    separately (see CollectionResult.error_full) for the DB audit trail."""
    text = str(exc).strip()
    keep: list[str] = []
    for raw in text.splitlines():
        ln = raw.strip()
        if not ln:
            continue
        # Stop at the first stack-frame-looking line (Java "at ...",
        # Python "File "...", or a "N more" continuation).
        if ln.startswith("at ") or ln.startswith('File "') or re.match(r"^\.{3}\s*\d+\s*more$", ln):
            break
        keep.append(ln)
        if len(keep) >= 2:
            break
    msg = " -- ".join(keep) if keep else (text.splitlines() or [exc.__class__.__name__])[0]
    msg = re.sub(r"\s+", " ", msg).strip(": ")
    if len(msg) > max_len:
        msg = msg[: max_len - 1].rstrip() + "…"
    return f"{exc.__class__.__name__}: {msg}"


# ---------------------------------------------------------------------------
# Spark session
# ---------------------------------------------------------------------------
def check_connector_compatibility() -> None:
    """Fail fast with one clear message instead of the same cryptic
    java.lang.NoSuchMethodError repeated for every collection.

    MONGO_CONNECTOR_PACKAGE (10.4.0) is built against Spark 3.x's Catalyst
    internals. Spark 4.x changed enough internal APIs (e.g.
    ExpressionEncoder.resolveAndBind's signature, the new
    org.apache.spark.sql.classic package) that the two are binary
    incompatible -- every read/count/write will crash.
    """
    major = int(pyspark.__version__.split(".")[0])
    if major >= 4:
        console.print(Panel.fit(
            f"[bold red]Incompatible versions detected[/bold red]\n"
            f"pyspark [yellow]{pyspark.__version__}[/yellow] is installed, but the pinned "
            f"connector\n[cyan]{MONGO_CONNECTOR_PACKAGE}[/cyan] only supports Spark 3.x.\n"
            f"Every collection would fail with java.lang.NoSuchMethodError.\n\n"
            f"[bold]Fix:[/bold] pin pyspark to a 3.5.x release to match the connector:\n"
            f"    pip install \"pyspark==3.5.5\" --break-system-packages\n"
            f"(or check mvnrepository.com for a mongo-spark-connector build\n"
            f"that targets Spark 4.x, once one ships).",
            border_style="red", title="Version check failed",
        ))
        raise SystemExit(2)


def build_spark_session() -> SparkSession:
    check_connector_compatibility()

    if not JDBC_JAR_PATH.exists():
        log.warning(f"Postgres JDBC jar not found at {JDBC_JAR_PATH}; "
                    f"JDBC writes will fail until it is placed there.")

    local_connector_jars = [JARS_DIR / name for name in MONGO_CONNECTOR_JAR_URLS]
    have_local_jars = all(p.exists() for p in local_connector_jars)

    builder = (
        SparkSession.builder.appName("mongo_exp")
        .config("spark.mongodb.read.connection.uri", config.MONGO_URI)
        .config("spark.mongodb.read.database", config.MONGO_DB)
        .config("spark.sql.session.timeZone", "UTC")
    )

    if have_local_jars:
        all_jars = ",".join([str(JDBC_JAR_PATH)] + [str(p) for p in local_connector_jars])
        builder = builder.config("spark.jars", all_jars)
        log.info("Building Spark session (using locally cached connector jars -- no download)")
    else:
        builder = (
            builder.config("spark.jars", str(JDBC_JAR_PATH))
            .config("spark.jars.packages", MONGO_CONNECTOR_PACKAGE)
        )
        log.info("Building Spark session (mongo connector package will be resolved via Ivy/Maven)")
        missing = [name for name, p in zip(MONGO_CONNECTOR_JAR_URLS, local_connector_jars) if not p.exists()]
        tip = "\n".join(f"  {name}\n    {MONGO_CONNECTOR_JAR_URLS[name]}" for name in missing)
        console.print(Panel(
            f"[yellow]Connector jars not found in {JARS_DIR} -- resolving via Maven this run "
            f"(that's the \":: resolving dependencies ::\" output below).[/yellow]\n\n"
            f"To skip this on every future run, download these into [cyan]{JARS_DIR}[/cyan]:\n\n{tip}",
            title="One-time setup tip", border_style="yellow",
        ))

    spark = builder.getOrCreate()
    spark.sparkContext.setLogLevel("WARN")
    return spark


def postgres_jdbc_url() -> str:
    return f"jdbc:postgresql://{config.POSTGRES_HOST}:{config.POSTGRES_PORT}/{config.POSTGRES_DATABASE}"


def postgres_jdbc_properties() -> dict:
    return {
        "user": config.POSTGRES_USERNAME,
        "password": config.POSTGRES_PASSWORD,
        "driver": "org.postgresql.Driver",
    }


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------
def discover_collections(mongo_db) -> list[str]:
    names = mongo_db.list_collection_names()
    collections = sorted(
        c for c in names if not any(c.startswith(p) for p in MONGO_SYSTEM_PREFIXES)
    )
    log.info(f"Discovered {len(collections)} collection(s) in '{config.MONGO_DB}': {collections}")
    return collections


def detect_incremental_column(sample_fields: list[str], override: Optional[str] = None) -> Optional[str]:
    """Pick the watermark column for a collection: an explicit override wins,
    otherwise the first candidate (in priority order) actually present on a
    sample document. Returns None if the collection has none of them."""
    if override:
        return override if override in sample_fields else None
    for candidate in INCREMENTAL_COLUMN_CANDIDATES:
        if candidate in sample_fields:
            return candidate
    return None


# ---------------------------------------------------------------------------
# Postgres metadata helpers (via SQLAlchemy, table-name-preserving)
# ---------------------------------------------------------------------------
def table_exists(pg_engine, table: str) -> bool:
    q = text(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables "
        "WHERE table_schema = :schema AND table_name = :table)"
    )
    with pg_engine.connect() as conn:
        return bool(conn.execute(q, {"schema": POSTGRES_SCHEMA, "table": table}).scalar())


def get_row_count(pg_engine, table: str) -> int:
    if not table_exists(pg_engine, table):
        return 0
    q = text(f'SELECT COUNT(*) FROM "{POSTGRES_SCHEMA}"."{table}"')
    with pg_engine.connect() as conn:
        return int(conn.execute(q).scalar() or 0)


def get_table_columns(pg_engine, table: str) -> list[str]:
    q = text(
        "SELECT column_name FROM information_schema.columns "
        "WHERE table_schema = :schema AND table_name = :table ORDER BY ordinal_position"
    )
    with pg_engine.connect() as conn:
        return [row[0] for row in conn.execute(q, {"schema": POSTGRES_SCHEMA, "table": table})]


def has_unique_index_on(pg_engine, table: str, column: str) -> bool:
    q = text("""
        SELECT 1
        FROM pg_index i
        JOIN pg_class t ON t.oid = i.indrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(i.indkey)
        WHERE n.nspname = :schema AND t.relname = :table
          AND a.attname = :column AND i.indisunique
          AND i.indnatts = 1
    """)
    with pg_engine.connect() as conn:
        return conn.execute(q, {"schema": POSTGRES_SCHEMA, "table": table, "column": column}).fetchone() is not None


def ensure_unique_id_index(pg_engine, table: str) -> bool:
    """Make sure `_id` has a unique index so ON CONFLICT ("_id") works.
    Returns True if the table can be safely merged into, False if not
    (e.g. duplicate _id values already exist from a prior append-only run)."""
    if has_unique_index_on(pg_engine, table, PRIMARY_KEY_COLUMN):
        return True
    index_name = f"{table}_{PRIMARY_KEY_COLUMN.strip('_')}_uidx"
    try:
        with pg_engine.begin() as conn:
            conn.execute(text(
                f'CREATE UNIQUE INDEX IF NOT EXISTS "{index_name}" '
                f'ON "{POSTGRES_SCHEMA}"."{table}" ("{PRIMARY_KEY_COLUMN}")'
            ))
        return True
    except SQLAlchemyError:
        log.warning(
            f"[{table}] could not create a unique index on \"{PRIMARY_KEY_COLUMN}\" "
            f"(likely duplicate values already present) -- upserts will fall back to append-only."
        )
        return False


def get_max_column_value(pg_engine, table: str, column: str) -> Optional[datetime]:
    if not table_exists(pg_engine, table) or column not in get_table_columns(pg_engine, table):
        return None
    with pg_engine.connect() as conn:
        return conn.execute(text(f'SELECT MAX("{column}") FROM "{POSTGRES_SCHEMA}"."{table}"')).scalar()


# ---------------------------------------------------------------------------
# Control tables: public.etl_watermarks (incremental state) and
# public.etl_logs (per-collection run history)
# ---------------------------------------------------------------------------
def ensure_control_tables(pg_engine) -> None:
    """Create the watermark + logs control tables if they don't exist yet,
    and add any new columns a prior version of this script didn't have.
    Fully idempotent -- safe to call on every run."""
    ddl_watermarks = f"""
        CREATE TABLE IF NOT EXISTS {POSTGRES_SCHEMA}.{WATERMARK_TABLE} (
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
        CREATE TABLE IF NOT EXISTS {POSTGRES_SCHEMA}.{LOG_TABLE} (
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
    with pg_engine.begin() as conn:
        conn.execute(text(ddl_watermarks))
        conn.execute(text(ddl_logs))
        # Forward-compatible migration in case these tables were created by
        # an earlier version of this script that didn't have every column.
        for stmt in [
            f'ALTER TABLE {POSTGRES_SCHEMA}.{WATERMARK_TABLE} ADD COLUMN IF NOT EXISTS incremental_column TEXT',
            f'ALTER TABLE {POSTGRES_SCHEMA}.{WATERMARK_TABLE} ADD COLUMN IF NOT EXISTS last_watermark_value TIMESTAMPTZ',
            f'ALTER TABLE {POSTGRES_SCHEMA}.{WATERMARK_TABLE} ADD COLUMN IF NOT EXISTS last_run_rows_inserted BIGINT NOT NULL DEFAULT 0',
            f'ALTER TABLE {POSTGRES_SCHEMA}.{WATERMARK_TABLE} ADD COLUMN IF NOT EXISTS last_run_rows_updated BIGINT NOT NULL DEFAULT 0',
            f'ALTER TABLE {POSTGRES_SCHEMA}.{LOG_TABLE} ADD COLUMN IF NOT EXISTS incremental_column TEXT',
            f'ALTER TABLE {POSTGRES_SCHEMA}.{LOG_TABLE} ADD COLUMN IF NOT EXISTS batch_rows BIGINT',
            f'ALTER TABLE {POSTGRES_SCHEMA}.{LOG_TABLE} ADD COLUMN IF NOT EXISTS rows_inserted BIGINT',
            f'ALTER TABLE {POSTGRES_SCHEMA}.{LOG_TABLE} ADD COLUMN IF NOT EXISTS rows_updated BIGINT',
        ]:
            conn.execute(text(stmt))
    log.info(f"Confirmed control tables exist: {POSTGRES_SCHEMA}.{WATERMARK_TABLE}, {POSTGRES_SCHEMA}.{LOG_TABLE}")


def get_watermark(pg_engine, table: str) -> Optional[datetime]:
    q = text(f'SELECT last_watermark_value FROM {POSTGRES_SCHEMA}.{WATERMARK_TABLE} WHERE table_name = :t')
    with pg_engine.connect() as conn:
        row = conn.execute(q, {"t": table}).fetchone()
        return row[0] if row else None


def upsert_watermark(
    pg_engine, table: str, incremental_column: Optional[str],
    last_value: Optional[datetime], mode: str, rows_inserted: int, rows_updated: int,
) -> None:
    q = text(f"""
        INSERT INTO {POSTGRES_SCHEMA}.{WATERMARK_TABLE}
            (table_name, incremental_column, last_watermark_value, last_run_at,
             last_run_mode, last_run_rows_inserted, last_run_rows_updated, updated_at)
        VALUES (:table, :col, :last_value, now(), :mode, :inserted, :updated, now())
        ON CONFLICT (table_name) DO UPDATE SET
            incremental_column     = EXCLUDED.incremental_column,
            last_watermark_value   = COALESCE(EXCLUDED.last_watermark_value,
                                               {POSTGRES_SCHEMA}.{WATERMARK_TABLE}.last_watermark_value),
            last_run_at            = EXCLUDED.last_run_at,
            last_run_mode           = EXCLUDED.last_run_mode,
            last_run_rows_inserted  = EXCLUDED.last_run_rows_inserted,
            last_run_rows_updated   = EXCLUDED.last_run_rows_updated,
            updated_at              = now()
    """)
    with pg_engine.begin() as conn:
        conn.execute(q, {
            "table": table, "col": incremental_column, "last_value": last_value,
            "mode": mode, "inserted": rows_inserted, "updated": rows_updated,
        })


def fetch_watermark_state(pg_engine) -> list[dict]:
    q = text(
        f"SELECT table_name, incremental_column, last_watermark_value, last_run_at, "
        f"last_run_mode, last_run_rows_inserted, last_run_rows_updated "
        f"FROM {POSTGRES_SCHEMA}.{WATERMARK_TABLE} ORDER BY table_name"
    )
    with pg_engine.connect() as conn:
        return [dict(row._mapping) for row in conn.execute(q)]


def insert_log(pg_engine, run_id: str, started_at: datetime, finished_at: datetime, r: "CollectionResult") -> None:
    """Best-effort audit row in public.etl_logs -- never let logging itself fail the run."""
    q = text(f"""
        INSERT INTO {POSTGRES_SCHEMA}.{LOG_TABLE}
            (run_id, table_name, mode, incremental_column, status, mongo_rows,
             postgres_rows_before, batch_rows, rows_inserted, rows_updated,
             skipped_rows, postgres_rows_after, columns_count, validation_status,
             validation_detail, error, started_at, finished_at, duration_seconds)
        VALUES
            (:run_id, :table_name, :mode, :incremental_column, :status, :mongo_rows,
             :postgres_rows_before, :batch_rows, :rows_inserted, :rows_updated,
             :skipped_rows, :postgres_rows_after, :columns_count, :validation_status,
             :validation_detail, :error, :started_at, :finished_at, :duration_seconds)
    """)
    try:
        with pg_engine.begin() as conn:
            conn.execute(q, {
                "run_id": run_id, "table_name": r.name, "mode": r.mode,
                "incremental_column": r.incremental_column, "status": r.status,
                "mongo_rows": r.mongo_rows, "postgres_rows_before": r.postgres_rows_before,
                "batch_rows": r.batch_rows, "rows_inserted": r.rows_inserted, "rows_updated": r.rows_updated,
                "skipped_rows": r.skipped_rows, "postgres_rows_after": r.postgres_rows_after,
                "columns_count": r.columns, "validation_status": r.validation_status,
                "validation_detail": r.validation_detail, "error": r.error_full or r.error,
                "started_at": started_at, "finished_at": finished_at, "duration_seconds": r.seconds,
            })
    except SQLAlchemyError:
        log.exception(f"[{r.name}] failed to write audit row to {POSTGRES_SCHEMA}.{LOG_TABLE} (non-fatal)")


def validate_collection(pg_engine, table: str, expected_after: int) -> tuple[str, str]:
    """Post-load validation: re-count the table fresh and compare against
    what we expect it to hold, independent of whatever Spark/the merge
    reported. Returns (status, detail)."""
    actual = get_row_count(pg_engine, table)
    if actual == expected_after:
        return "PASS", f"{actual:,} rows confirmed in Postgres"
    return "FAIL", f"expected {expected_after:,}, found {actual:,} in Postgres"


# ---------------------------------------------------------------------------
# Mongo read (pushdown filter for incremental loads)
# ---------------------------------------------------------------------------
def read_collection(
    spark: SparkSession, collection: str, incremental_column: Optional[str], since: Optional[datetime]
) -> DataFrame:
    reader = (
        spark.read.format("mongodb")
        .option("connection.uri", config.MONGO_URI)
        .option("database", config.MONGO_DB)
        .option("collection", collection)
    )
    if incremental_column and since is not None:
        # NOTE: the watermark columns (updated_timestamp / updated_at /
        # created_timestamp / created_at) are stored in Mongo as plain
        # strings in "YYYY-MM-DD HH:MM:SS" format, NOT as BSON dates.
        # MongoDB never matches across BSON types in a comparison operator
        # (a string is never $gt a date, regardless of the actual values),
        # so the filter must compare string-to-string in the same format
        # the field is actually stored in -- lexicographic ordering on this
        # fixed-width, zero-padded format is equivalent to chronological
        # ordering. If the upstream data is ever migrated to real BSON
        # dates, this must switch back to the {"$date": iso} form.
        watermark_str = since.strftime("%Y-%m-%d %H:%M:%S")
        pipeline = json.dumps([{"$match": {incremental_column: {"$gt": watermark_str}}}])
        reader = reader.option("aggregation.pipeline", pipeline)
    return reader.load()


def sanitize_for_postgres(df: DataFrame, log_flattened: list) -> DataFrame:
    """
    Make the frame writable via plain JDBC without touching any column's
    *logical* meaning. Only two adjustments are made, both unavoidable:
      - `_id` (BSON ObjectId) -> string (also our merge key)
      - nested struct/array/map columns -> JSON string (Postgres has no
        native equivalent over plain JDBC)
    Every other column keeps whatever type Spark inferred from Mongo.
    """
    out = df
    if PRIMARY_KEY_COLUMN in out.columns:
        out = out.withColumn(PRIMARY_KEY_COLUMN, F.col(PRIMARY_KEY_COLUMN).cast("string"))

    for f in out.schema.fields:
        if isinstance(f.dataType, (StructType, ArrayType, MapType)):
            out = out.withColumn(f.name, F.to_json(F.col(f.name)))
            log_flattened.append(f.name)

    return out


# ---------------------------------------------------------------------------
# Write path: direct append for a brand-new table, staging + upsert-merge
# for an existing one.
# ---------------------------------------------------------------------------
def write_direct(df: DataFrame, collection: str) -> None:
    (
        df.write.format("jdbc")
        .option("url", postgres_jdbc_url())
        .option("dbtable", f"{POSTGRES_SCHEMA}.{collection}")
        .options(**postgres_jdbc_properties())
        .mode("append")
        .save()
    )


def write_staging(df: DataFrame, staging_table: str) -> None:
    (
        df.write.format("jdbc")
        .option("url", postgres_jdbc_url())
        .option("dbtable", f"{POSTGRES_SCHEMA}.{staging_table}")
        .options(**postgres_jdbc_properties())
        .mode("overwrite")   # scratch table -- drop/recreate fresh every run
        .save()
    )


def merge_staging_into_target(pg_engine, collection: str, staging_table: str, columns: list[str]) -> tuple[int, int]:
    """INSERT ... ON CONFLICT (_id) DO UPDATE, using xmax=0 to split the
    result into (rows_inserted, rows_updated) counts. Returns that tuple."""
    quoted_cols = ", ".join(f'"{c}"' for c in columns)
    update_cols = [c for c in columns if c != PRIMARY_KEY_COLUMN]
    set_clause = ", ".join(f'"{c}" = EXCLUDED."{c}"' for c in update_cols)

    merge_sql = f"""
        WITH upsert AS (
            INSERT INTO "{POSTGRES_SCHEMA}"."{collection}" ({quoted_cols})
            SELECT {quoted_cols} FROM "{POSTGRES_SCHEMA}"."{staging_table}"
            ON CONFLICT ("{PRIMARY_KEY_COLUMN}") DO UPDATE SET {set_clause}
            RETURNING (xmax = 0) AS inserted
        )
        SELECT
            count(*) FILTER (WHERE inserted)     AS rows_inserted,
            count(*) FILTER (WHERE NOT inserted) AS rows_updated
        FROM upsert
    """
    with pg_engine.begin() as conn:
        row = conn.execute(text(merge_sql)).fetchone()
    return int(row[0] or 0), int(row[1] or 0)


def drop_table(pg_engine, table: str) -> None:
    with pg_engine.begin() as conn:
        conn.execute(text(f'DROP TABLE IF EXISTS "{POSTGRES_SCHEMA}"."{table}"'))


# ---------------------------------------------------------------------------
# Per-collection pipeline
# ---------------------------------------------------------------------------
def process_collection(
    spark: SparkSession,
    mongo_db,
    pg_engine,
    collection: str,
    full_refresh: bool,
    dry_run: bool,
    run_id: str,
    watermark_column_override: Optional[str],
) -> CollectionResult:
    start = time.time()
    started_at = datetime.now()
    result = CollectionResult(name=collection)

    try:
        mongo_total = mongo_db[collection].estimated_document_count()
        result.mongo_rows = mongo_total

        pg_before = get_row_count(pg_engine, collection)
        result.postgres_rows_before = pg_before

        sample = mongo_db[collection].find_one()
        sample_fields = list(sample.keys()) if sample else []
        incremental_column = detect_incremental_column(sample_fields, watermark_column_override)
        result.incremental_column = incremental_column

        if full_refresh:
            since = None
        elif incremental_column:
            since = get_watermark(pg_engine, collection)
        else:
            since = None
            log.warning(
                f"[{collection}] no incremental column found among {INCREMENTAL_COLUMN_CANDIDATES}; "
                f"every run will fully reload this collection."
            )
        result.watermark_before = since
        result.mode = "full" if since is None else "incremental"

        if full_refresh and table_exists(pg_engine, collection):
            log.info(f"[{collection}] --full-refresh: truncating table before reload")
            if not dry_run:
                with pg_engine.begin() as conn:
                    conn.execute(text(f'TRUNCATE TABLE "{POSTGRES_SCHEMA}"."{collection}"'))
                pg_before = 0
                result.postgres_rows_before = 0

        df = read_collection(spark, collection, incremental_column, since)
        df = sanitize_for_postgres(df, result.complex_fields_flattened)
        result.columns = len(df.columns)

        batch_rows = df.count()
        result.batch_rows = batch_rows
        result.skipped_rows = max(mongo_total - batch_rows, 0)

        new_watermark = since
        if batch_rows > 0 and incremental_column and incremental_column in df.columns:
            new_watermark = df.agg(F.max(incremental_column)).collect()[0][0] or since
        result.watermark_after = new_watermark

        if batch_rows == 0:
            result.status = "SKIPPED (no new/changed rows)"
            result.postgres_rows_after = pg_before
            result.validation_status, result.validation_detail = validate_collection(pg_engine, collection, pg_before)
            if not dry_run:
                upsert_watermark(pg_engine, collection, incremental_column, new_watermark, result.mode, 0, 0)
            log.info(f"[{collection}] nothing new to load (mode={result.mode})")
            return result

        if dry_run:
            result.status = "DRY-RUN"
            result.postgres_rows_after = pg_before
            log.info(f"[{collection}] dry-run: would merge {batch_rows} row(s)")
            return result

        target_exists = table_exists(pg_engine, collection)
        can_merge = PRIMARY_KEY_COLUMN in df.columns

        if not target_exists:
            # First-ever load for this collection: plain JDBC append both
            # creates the table (Spark infers the schema) and populates it.
            log.info(f"[{collection}] first load: creating table and inserting {batch_rows} row(s)")
            write_direct(df, collection)
            result.rows_inserted, result.rows_updated = batch_rows, 0
            ensure_unique_id_index(pg_engine, collection)
        elif not can_merge:
            log.warning(f"[{collection}] no \"{PRIMARY_KEY_COLUMN}\" column present -- appending instead of upserting")
            write_direct(df, collection)
            result.rows_inserted, result.rows_updated = batch_rows, 0
        else:
            merge_ready = ensure_unique_id_index(pg_engine, collection)
            if not merge_ready:
                log.warning(f"[{collection}] falling back to append-only for this run")
                write_direct(df, collection)
                result.rows_inserted, result.rows_updated = batch_rows, 0
            else:
                staging_table = f"_stg_{collection}"
                log.info(f"[{collection}] merging {batch_rows} row(s) via staging table {staging_table}")
                write_staging(df, staging_table)
                try:
                    result.rows_inserted, result.rows_updated = merge_staging_into_target(
                        pg_engine, collection, staging_table, df.columns
                    )
                finally:
                    drop_table(pg_engine, staging_table)

        expected_after = pg_before + result.rows_inserted
        result.postgres_rows_after = get_row_count(pg_engine, collection)
        result.validation_status, result.validation_detail = validate_collection(pg_engine, collection, expected_after)

        if result.validation_status == "PASS":
            upsert_watermark(
                pg_engine, collection, incremental_column, new_watermark,
                result.mode, result.rows_inserted, result.rows_updated,
            )
            result.status = "OK"
        else:
            result.status = "VALIDATION FAILED"
            log.error(f"[{collection}] post-load validation FAILED: {result.validation_detail}")

    except Exception as exc:  # noqa: BLE001 - we want to keep going for other collections
        result.status = "FAILED"
        result.error = short_error(exc)
        result.error_full = traceback.format_exc()
        # log.error (not log.exception) -- deliberately no traceback attached,
        # so this doesn't flood the console/log with the full Java+Python
        # stack trace. Full detail still lands in public.etl_logs.error.
        log.error(f"[{collection}] extraction failed: {result.error}")
    finally:
        result.seconds = time.time() - start
        finished_at = datetime.now()
        insert_log(pg_engine, run_id, started_at, finished_at, result)

    return result


# ---------------------------------------------------------------------------
# Rich reporting
# ---------------------------------------------------------------------------
def render_report(results: list[CollectionResult], elapsed: float, dry_run: bool, run_id: str, pg_engine=None):
    console.print()
    console.print(Panel.fit(
        "[bold]MongoDB -> PostgreSQL Extraction Report[/bold]\n"
        f"Database: [cyan]{config.MONGO_DB}[/cyan]  →  Schema: [cyan]{POSTGRES_SCHEMA}[/cyan]\n"
        f"Run ID: [magenta]{run_id}[/magenta]\n"
        f"Run finished: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
        + ("  [yellow](DRY RUN - no data written)[/yellow]" if dry_run else ""),
        border_style="cyan",
    ))

    table = Table(title="Per-Collection Detail", box=box.SIMPLE_HEAVY, show_lines=False)
    table.add_column("Table", style="bold")
    table.add_column("Mode")
    table.add_column("Watermark Col")
    table.add_column("Mongo Rows", justify="right")
    table.add_column("PG Rows (Before)", justify="right")
    table.add_column("Inserted", justify="right", style="green")
    table.add_column("Updated", justify="right", style="cyan")
    table.add_column("Skipped", justify="right", style="yellow")
    table.add_column("PG Rows (After)", justify="right")
    table.add_column("Columns", justify="right")
    table.add_column("Time (s)", justify="right")
    table.add_column("Status")
    table.add_column("Validation")

    for r in results:
        status_style = {
            "OK": "green", "DRY-RUN": "cyan",
        }.get(r.status, "yellow" if "SKIPPED" in r.status else "red")
        validation_style = {"PASS": "green", "N/A": "dim"}.get(r.validation_status, "red")
        table.add_row(
            r.name,
            r.mode,
            r.incremental_column or "-",
            f"{r.mongo_rows:,}",
            f"{r.postgres_rows_before:,}",
            f"{r.rows_inserted:,}",
            f"{r.rows_updated:,}",
            f"{r.skipped_rows:,}",
            f"{r.postgres_rows_after:,}",
            str(r.columns),
            f"{r.seconds:.2f}",
            f"[{status_style}]{r.status}[/{status_style}]",
            f"[{validation_style}]{r.validation_status}[/{validation_style}]",
        )
    console.print(table)

    validation_issues = [r for r in results if r.validation_status == "FAIL"]
    if validation_issues:
        vtable = Table(title="Post-Load Validation Detail", box=box.MINIMAL, style="red")
        vtable.add_column("Table")
        vtable.add_column("Detail")
        for r in validation_issues:
            vtable.add_row(r.name, r.validation_detail)
        console.print(vtable)

    if pg_engine is not None:
        try:
            state = fetch_watermark_state(pg_engine)
        except SQLAlchemyError:
            state = []
        if state:
            wtable = Table(
                title=f"Watermark State ({POSTGRES_SCHEMA}.{WATERMARK_TABLE})",
                box=box.MINIMAL_DOUBLE_HEAD,
            )
            wtable.add_column("Table")
            wtable.add_column("Watermark Col")
            wtable.add_column("Last Value Loaded")
            wtable.add_column("Last Run At")
            wtable.add_column("Last Mode")
            wtable.add_column("Ins", justify="right")
            wtable.add_column("Upd", justify="right")
            for row in state:
                wtable.add_row(
                    row["table_name"],
                    row["incremental_column"] or "-",
                    str(row["last_watermark_value"]) if row["last_watermark_value"] else "-",
                    str(row["last_run_at"]),
                    row["last_run_mode"] or "-",
                    f"{row['last_run_rows_inserted']:,}",
                    f"{row['last_run_rows_updated']:,}",
                )
            console.print(wtable)
        console.print(
            f"[dim]Full per-collection audit trail for every run is stored in "
            f"{POSTGRES_SCHEMA}.{LOG_TABLE} (run_id = {run_id}).[/dim]"
        )

    flattened = {r.name: r.complex_fields_flattened for r in results if r.complex_fields_flattened}
    if flattened:
        note = Table(title="Nested Fields Serialized to JSON (unavoidable for JDBC)", box=box.MINIMAL)
        note.add_column("Table")
        note.add_column("Fields")
        for name, fields_ in flattened.items():
            note.add_row(name, ", ".join(fields_))
        console.print(note)

    failed = [r for r in results if r.status == "FAILED"]
    if failed:
        err_table = Table(title="Failures", box=box.MINIMAL, style="red")
        err_table.add_column("Table", no_wrap=True)
        err_table.add_column("Error", overflow="fold", max_width=90)
        for r in failed:
            err_table.add_row(r.name, r.error or "unknown error")
        console.print(err_table)

    total_mongo = sum(r.mongo_rows for r in results)
    total_inserted = sum(r.rows_inserted for r in results)
    total_updated = sum(r.rows_updated for r in results)
    total_skipped = sum(r.skipped_rows for r in results)
    total_pg_after = sum(r.postgres_rows_after for r in results)
    n_succeeded = sum(1 for r in results if r.status == "OK")
    n_skipped = sum(1 for r in results if "SKIPPED" in r.status)
    has_issues = bool(failed) or bool(validation_issues)

    outcome = Table(
        title="Run Outcome", box=box.ROUNDED, title_style="bold",
        header_style="bold cyan", border_style="red" if has_issues else "green",
        show_lines=False,
    )
    for col in ("Collections", "Succeeded", "Skipped", "Failed", "Validation Failures", "Run Time"):
        outcome.add_column(col, justify="center")
    outcome.add_row(
        str(len(results)),
        f"[green]{n_succeeded}[/green]",
        f"[yellow]{n_skipped}[/yellow]",
        f"[red]{len(failed)}[/red]" if failed else "0",
        f"[red]{len(validation_issues)}[/red]" if validation_issues else "0",
        f"{elapsed:.2f}s",
    )

    totals = Table(
        title="Row Totals", box=box.ROUNDED, title_style="bold",
        header_style="bold cyan", border_style="cyan",
        show_lines=False,
    )
    for col in ("Mongo Rows", "Inserted", "Updated", "Skipped (unchanged)", "Now in Postgres"):
        totals.add_column(col, justify="center")
    totals.add_row(
        f"{total_mongo:,}",
        f"[green]{total_inserted:,}[/green]",
        f"[cyan]{total_updated:,}[/cyan]",
        f"[yellow]{total_skipped:,}[/yellow]",
        f"{total_pg_after:,}",
    )
    console.print(Columns([outcome, totals], padding=(0, 2)))

    console.print(Panel(
        f"[bold {'red' if has_issues else 'green'}]{'RUN COMPLETED WITH ISSUES' if has_issues else 'RUN COMPLETED SUCCESSFULLY'}[/bold {'red' if has_issues else 'green'}]",
        border_style="red" if has_issues else "green",
    ))


# ---------------------------------------------------------------------------
# CLI / main
# ---------------------------------------------------------------------------
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Incremental MongoDB -> PostgreSQL extractor (PySpark).")
    parser.add_argument(
        "--tables", type=str, default=None,
        help="Comma-separated list of collection names to process (default: all discovered collections).",
    )
    parser.add_argument(
        "--full-refresh", action="store_true",
        help="Ignore watermark state and reload every discovered collection from scratch "
             "(truncates existing Postgres tables before merging).",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Discover, count, and compute what would be loaded -- do not write anything to Postgres.",
    )
    parser.add_argument(
        "--watermark-column", type=str, default=None,
        help="Force a specific column name as the incremental watermark for every collection "
             "(default: auto-detect per collection from "
             f"{INCREMENTAL_COLUMN_CANDIDATES}).",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    start = time.time()
    run_id = f"{datetime.now():%Y%m%d_%H%M%S}_{uuid.uuid4().hex[:6]}"

    console.rule("[bold cyan]mongo_exp: MongoDB -> PostgreSQL incremental extraction[/bold cyan]")
    log.info(f"Starting run {run_id} (full_refresh={args.full_refresh}, dry_run={args.dry_run}, tables={args.tables})")

    mongo_db = get_mongo_db()
    pg_engine = create_engine(
        f"postgresql+psycopg2://{config.POSTGRES_USERNAME}:{config.POSTGRES_PASSWORD}"
        f"@{config.POSTGRES_HOST}:{config.POSTGRES_PORT}/{config.POSTGRES_DATABASE}"
    )
    ensure_control_tables(pg_engine)

    if args.tables:
        collections = [t.strip() for t in args.tables.split(",") if t.strip()]
        log.info(f"Restricting run to user-specified collections: {collections}")
    else:
        collections = discover_collections(mongo_db)

    if not collections:
        console.print("[yellow]No collections found to process.[/yellow]")
        return 0

    spark = build_spark_session()
    results: list[CollectionResult] = []

    try:
        with Progress(
            SpinnerColumn(), TextColumn("[bold blue]{task.fields[coll]}"),
            BarColumn(), TextColumn("{task.completed}/{task.total}"),
            TimeElapsedColumn(), console=console,
        ) as progress:
            task = progress.add_task("extract", total=len(collections), coll="starting...")
            for coll in collections:
                progress.update(task, coll=coll)
                res = process_collection(
                    spark, mongo_db, pg_engine, coll, args.full_refresh, args.dry_run,
                    run_id, args.watermark_column,
                )
                results.append(res)
                progress.advance(task)
    finally:
        # Spark's own cleanup on stop() tries to delete its local temp dir;
        # on Windows the JVM often still holds a file handle on a jar we
        # passed in (postgresql.jar), so the delete fails and Spark logs a
        # WARN + full Java stack trace. It's cosmetic -- the run has already
        # completed successfully by this point -- so raise the threshold
        # just for the stop() call to keep it out of the console.
        spark.sparkContext.setLogLevel("ERROR")
        spark.stop()

    elapsed = time.time() - start
    render_report(results, elapsed, args.dry_run, run_id, pg_engine)

    log.info(f"Run {run_id} complete in {elapsed:.2f}s")
    return 1 if any(r.status in ("FAILED", "VALIDATION FAILED") for r in results) else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SQLAlchemyError:
        console.print_exception()
        sys.exit(2)
    except Exception:  # noqa: BLE001
        console.print("[bold red]Unhandled error:[/bold red]")
        console.print(traceback.format_exc())
        sys.exit(2)