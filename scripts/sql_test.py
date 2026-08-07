"""
Runs every .sql file in a given test directory against Postgres.

Supports TWO test conventions, auto-detected per file:

  1. SELECT-style tests (e.g. dbt generic tests, tests/silver/*.sql,
     tests/gold/*.sql):
       - The query SELECTs the rows that VIOLATE the rule.
       - Empty result set  -> PASS
       - Any rows returned -> FAIL (rows written to the log file)

  2. DO-block-style tests (e.g. tests/bronze/*.sql loops that RAISE EXCEPTION):
       - The script does its own looping/checking in a DO $$ ... $$ block
         and raises an exception itself when something is wrong.
       - No exception raised -> PASS (the block returns no rows at all,
         which is normal and NOT an error)
       - Exception raised    -> FAIL, exception message logged as the reason

Usage:
    uv run python scripts/sql_test.py tests/bronze
    uv run python scripts/sql_test.py tests/silver
    uv run python scripts/sql_test.py tests/gold

Exit code: 0 if all tests pass, 1 if any test fails.

Console output stays minimal (one line per test). Full detail — including
failing rows or exception messages — goes to the rotating log file under
logs/, via utils/logger.py.

Reads Postgres connection info from environment variables (loaded from .env
by run_pipeline.ps1 before this is called):
    POSTGRES_HOST, POSTGRES_PORT, POSTGRES_DATABASE,
    POSTGRES_USERNAME, POSTGRES_PASSWORD
"""

import os
import sys
from pathlib import Path

from sqlalchemy import create_engine, text
from sqlalchemy.exc import ResourceClosedError, SQLAlchemyError

from utils.logger import get_logger

PREVIEW_ROWS = 5


def get_engine():
    host = os.environ["POSTGRES_HOST"]
    port = os.environ["POSTGRES_PORT"]
    db = os.environ["POSTGRES_DATABASE"]
    user = os.environ["POSTGRES_USERNAME"]
    pw = os.environ["POSTGRES_PASSWORD"]
    url = f"postgresql+psycopg2://{user}:{pw}@{host}:{port}/{db}"
    return create_engine(url)


def run_tests(test_dir: Path, log) -> bool:
    sql_files = sorted(test_dir.glob("*.sql"))
    if not sql_files:
        log.warning(f"No .sql test files found in {test_dir}")
        return True

    engine = get_engine()
    all_passed = True

    with engine.connect() as conn:
        for sql_file in sql_files:
            query = sql_file.read_text()

            try:
                result = conn.execute(text(query))
                conn.commit()

                # Statement ran without raising. Two possibilities:
                #   - it's a SELECT and may have returned rows to check
                #   - it's a DO block / DDL / etc. with no result set at all,
                #     which is NOT a failure by itself
                try:
                    rows = result.fetchall()
                except ResourceClosedError:
                    rows = []

            except SQLAlchemyError as exc:
                # Real DB errors AND `RAISE EXCEPTION` from a DO block both
                # surface here as SQLAlchemy-wrapped DBAPI errors. Either way,
                # roll back so the connection is usable for the next test
                # file, then record it as a failure.
                conn.rollback()
                all_passed = False
                log.error(f"{sql_file.name}: FAIL - {exc}")
                continue

            if not rows:
                log.info(f"{sql_file.name}: PASS")
            else:
                all_passed = False
                log.error(f"{sql_file.name}: FAIL ({len(rows)} failing row(s))")
                for row in rows[:PREVIEW_ROWS]:
                    log.debug(f"  {sql_file.name} -> {row}")
                if len(rows) > PREVIEW_ROWS:
                    log.debug(
                        f"  {sql_file.name} -> ... {len(rows) - PREVIEW_ROWS} more row(s), see full query for details"
                    )

    return all_passed


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: sql_test.py <test_dir>")
        sys.exit(2)

    target_dir = Path(sys.argv[1])
    logger_name = f"sql_tests_{target_dir.name}"
    log = get_logger(logger_name, console_level=None)

    if not target_dir.exists():
        log.error(f"Directory not found: {target_dir}")
        sys.exit(2)

    passed = run_tests(target_dir, log)
    sys.exit(0 if passed else 1)
