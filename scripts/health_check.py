"""Display a non-destructive health report for the Walmart ETL project.

Lives in ``scripts/``; ``PROJECT_ROOT`` resolves one level up so every path
below (docker/, logs/, .env, git) still points at the repo root regardless
of your current directory.

Run with ``uv run python scripts/health_check.py`` from the repo root, or
``uv run python health_check.py`` from inside ``scripts/``.  The script
reads connection settings from ``.env`` (or the current environment) but
never prints secrets.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import urlopen

from dotenv import load_dotenv
from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

PROJECT_ROOT = Path(__file__).resolve().parent.parent
COMPOSE_FILE = PROJECT_ROOT / "docker" / "compose.yml"
PIPELINE_LOG_DIR = PROJECT_ROOT / "logs"
AIRFLOW_HEALTH_URL = "http://localhost:8080/api/v2/monitor/health"
CONNECTION_TIMEOUT_SECONDS = 5


class Status(StrEnum):
    """The outcome of one health check."""

    PASS = "PASS"
    WARN = "WARN"
    FAIL = "FAIL"
    SKIP = "SKIP"


@dataclass(frozen=True)
class CheckResult:
    """A single health check result rendered in the terminal report."""

    component: str
    status: Status
    detail: str


def run_command(
    *command: str, timeout: int = CONNECTION_TIMEOUT_SECONDS
) -> subprocess.CompletedProcess[str]:
    """Run a read-only system command and capture its text output."""

    return subprocess.run(
        command,
        capture_output=True,
        check=False,
        cwd=PROJECT_ROOT,
        text=True,
        timeout=timeout,
    )


def environment_value(name: str) -> str | None:
    """Return a configured environment variable, treating blank values as absent."""

    value = os.getenv(name)
    return value.strip() if value and value.strip() else None


def check_postgres() -> CheckResult:
    """Connect to Postgres and run a minimal query."""

    required = (
        "POSTGRES_HOST",
        "POSTGRES_PORT",
        "POSTGRES_DATABASE",
        "POSTGRES_USERNAME",
        "POSTGRES_PASSWORD",
    )
    missing = [name for name in required if not environment_value(name)]
    if missing:
        return CheckResult(
            "Postgres", Status.FAIL, f"missing configuration: {', '.join(missing)}"
        )

    try:
        from sqlalchemy import URL, create_engine, text
        from sqlalchemy.exc import SQLAlchemyError
    except ImportError as error:
        return CheckResult(
            "Postgres", Status.FAIL, f"database dependency is unavailable: {error}"
        )

    try:
        url = URL.create(
            "postgresql+psycopg2",
            username=environment_value("POSTGRES_USERNAME"),
            password=environment_value("POSTGRES_PASSWORD"),
            host=environment_value("POSTGRES_HOST"),
            port=int(environment_value("POSTGRES_PORT") or 0),
            database=environment_value("POSTGRES_DATABASE"),
        )
        engine = create_engine(
            url, connect_args={"connect_timeout": CONNECTION_TIMEOUT_SECONDS}
        )
        try:
            with engine.connect() as connection:
                version = str(connection.execute(text("SELECT version()")).scalar_one())
        finally:
            engine.dispose()
        return CheckResult("Postgres", Status.PASS, version.split(",")[0])
    except (OSError, SQLAlchemyError, ValueError) as error:
        return CheckResult("Postgres", Status.FAIL, f"connection failed: {error}")


def check_mongo() -> CheckResult:
    """Ping the configured MongoDB server."""

    uri = environment_value("MONGO_URI")
    database = environment_value("MONGO_DB")
    if not uri or not database:
        return CheckResult("MongoDB", Status.FAIL, "missing MONGO_URI or MONGO_DB")

    try:
        from pymongo import MongoClient
        from pymongo.errors import PyMongoError
    except ImportError as error:
        return CheckResult(
            "MongoDB", Status.FAIL, f"database dependency is unavailable: {error}"
        )

    try:
        client = MongoClient(
            uri, serverSelectionTimeoutMS=CONNECTION_TIMEOUT_SECONDS * 1000
        )
        try:
            client.admin.command("ping")
        finally:
            client.close()
        return CheckResult(
            "MongoDB", Status.PASS, f"ping succeeded for database '{database}'"
        )
    except (PyMongoError, ValueError) as error:
        return CheckResult("MongoDB", Status.FAIL, f"connection failed: {error}")


def check_pyspark(quick: bool) -> CheckResult:
    """Verify PySpark's version and, unless quick, start a local Spark session."""

    try:
        import pyspark
    except ImportError:
        return CheckResult(
            "PySpark", Status.FAIL, "pyspark is not installed; run 'uv sync'"
        )

    jars_present = (
        PROJECT_ROOT / "jars" / "mongo-spark-connector_2.12-10.4.0.jar"
    ).is_file()
    jar_detail = (
        "Mongo connector jar found"
        if jars_present
        else "Mongo connector jar is missing"
    )
    if quick:
        status = Status.PASS if jars_present else Status.WARN
        return CheckResult(
            "PySpark",
            status,
            f"version {pyspark.__version__}; {jar_detail}; runtime skipped",
        )

    try:
        from pyspark.errors import PySparkException
        from pyspark.sql import SparkSession
    except ImportError as error:
        return CheckResult(
            "PySpark", Status.FAIL, f"PySpark runtime is unavailable: {error}"
        )

    spark: Any | None = None
    started_at = time.monotonic()
    try:
        spark = (
            SparkSession.builder.master("local[1]")
            .appName("walmart-health-check")
            .getOrCreate()
        )
        spark.range(1).count()
        duration = time.monotonic() - started_at
        status = Status.PASS if jars_present else Status.WARN
        return CheckResult(
            "PySpark",
            status,
            f"version {pyspark.__version__}; local session OK in {duration:.1f}s; {jar_detail}",
        )
    except (OSError, PySparkException, RuntimeError, ValueError) as error:
        return CheckResult("PySpark", Status.FAIL, f"local session failed: {error}")
    finally:
        if spark is not None:
            spark.stop()


def check_docker() -> CheckResult:
    """Verify that Docker's CLI can contact its daemon."""

    try:
        result = run_command("docker", "version", "--format", "{{.Server.Version}}")
    except FileNotFoundError:
        return CheckResult(
            "Docker", Status.FAIL, "docker CLI is not installed or is not on PATH"
        )
    except subprocess.TimeoutExpired:
        return CheckResult(
            "Docker", Status.FAIL, "Docker daemon did not respond within 5 seconds"
        )

    if result.returncode != 0:
        detail = (
            result.stderr.strip()
            or result.stdout.strip()
            or "Docker daemon is unavailable"
        )
        return CheckResult("Docker", Status.FAIL, detail)
    return CheckResult("Docker", Status.PASS, f"daemon version {result.stdout.strip()}")


def check_airflow() -> CheckResult:
    """Request the local Airflow API health endpoint."""

    try:
        with urlopen(
            AIRFLOW_HEALTH_URL, timeout=CONNECTION_TIMEOUT_SECONDS
        ) as response:
            body = json.loads(response.read().decode("utf-8"))
        services = ", ".join(f"{name}: {value}" for name, value in body.items())
        return CheckResult("Airflow", Status.PASS, f"API healthy ({services})")
    except HTTPError as error:
        return CheckResult(
            "Airflow", Status.FAIL, f"health endpoint returned HTTP {error.code}"
        )
    except (OSError, URLError, TimeoutError, json.JSONDecodeError) as error:
        return CheckResult(
            "Airflow", Status.WARN, f"API unavailable at :8080 ({error})"
        )


def check_compose_services() -> CheckResult:
    """Summarize running Docker Compose services when the stack exists."""

    if not COMPOSE_FILE.is_file():
        return CheckResult(
            "Compose stack", Status.SKIP, "docker/compose.yml is not present"
        )

    try:
        result = run_command(
            "docker",
            "compose",
            "-f",
            str(COMPOSE_FILE),
            "ps",
            "--all",
            "--format",
            "json",
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return CheckResult("Compose stack", Status.SKIP, "Docker is unavailable")

    if result.returncode != 0:
        return CheckResult(
            "Compose stack",
            Status.WARN,
            result.stderr.strip() or "could not inspect stack",
        )
    try:
        rows = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    except json.JSONDecodeError:
        return CheckResult(
            "Compose stack", Status.WARN, "Docker returned an unreadable service list"
        )
    if not rows:
        return CheckResult(
            "Compose stack", Status.WARN, "no Airflow Compose services are running"
        )

    unhealthy = [
        row.get("Service", row.get("Name", "unknown"))
        for row in rows
        if "unhealthy" in row.get("Status", "").lower()
    ]
    running = sum(
        "running" in row.get("State", row.get("Status", "")).lower() for row in rows
    )
    stopped = [
        row.get("Service", row.get("Name", "unknown"))
        for row in rows
        if row.get("Service") != "airflow-init"
        and "running" not in row.get("State", row.get("Status", "")).lower()
    ]
    if unhealthy:
        return CheckResult(
            "Compose stack", Status.FAIL, f"unhealthy: {', '.join(unhealthy)}"
        )
    if stopped:
        return CheckResult(
            "Compose stack", Status.WARN, f"not running: {', '.join(stopped)}"
        )
    return CheckResult(
        "Compose stack", Status.PASS, f"{running}/{len(rows)} services running"
    )


def check_pipeline_run() -> CheckResult:
    """Report the outcome recorded by the latest PowerShell pipeline log."""

    logs = sorted(
        PIPELINE_LOG_DIR.glob("pipeline_*.log"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if not logs:
        return CheckResult("Last PowerShell run", Status.WARN, "no pipeline logs found")

    latest_log = logs[0]
    lines = latest_log.read_text(encoding="utf-8", errors="replace").splitlines()
    last_status_line = next(
        (
            line
            for line in reversed(lines)
            if "Pipeline completed successfully" in line
            or "failed - stopping" in line
            or "Pipeline started" in line
        ),
        "",
    )
    timestamp = (
        datetime.fromtimestamp(latest_log.stat().st_mtime)
        .astimezone()
        .strftime("%Y-%m-%d %H:%M:%S %Z")
    )
    prefix = f"{latest_log.name} ({timestamp})"
    if "completed successfully" in last_status_line:
        return CheckResult(
            "Last PowerShell run", Status.PASS, f"completed successfully — {prefix}"
        )
    if "failed - stopping" in last_status_line:
        return CheckResult("Last PowerShell run", Status.FAIL, f"failed — {prefix}")
    return CheckResult(
        "Last PowerShell run", Status.WARN, f"started but no final outcome — {prefix}"
    )


def check_git() -> CheckResult:
    """Show the latest commit and whether the working tree is clean."""

    try:
        commit = run_command(
            "git", "log", "-1", "--format=%h | %ad | %s", "--date=short"
        )
        state = run_command("git", "status", "--porcelain")
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return CheckResult("Git", Status.WARN, "git is unavailable")

    if commit.returncode != 0:
        return CheckResult(
            "Git", Status.WARN, commit.stderr.strip() or "could not read latest commit"
        )
    changes = [line for line in state.stdout.splitlines() if line]
    suffix = (
        "working tree clean" if not changes else f"{len(changes)} uncommitted change(s)"
    )
    status = Status.PASS if not changes else Status.WARN
    return CheckResult("Git", status, f"{commit.stdout.strip()} — {suffix}")


def render_report(results: list[CheckResult]) -> None:
    """Render individual checks and an overall result with Rich."""

    console = Console()
    styles = {
        Status.PASS: "green",
        Status.WARN: "yellow",
        Status.FAIL: "red",
        Status.SKIP: "dim",
    }
    icons = {Status.PASS: "OK", Status.WARN: "!", Status.FAIL: "X", Status.SKIP: "-"}
    table = Table(title="Walmart Medallion Pipeline Health", show_lines=True)
    table.add_column("Component", style="bold cyan", no_wrap=True)
    table.add_column("Status", justify="center", no_wrap=True)
    table.add_column("Detail")
    for result in results:
        table.add_row(
            result.component,
            Text(
                f"{icons[result.status]} {result.status}", style=styles[result.status]
            ),
            result.detail,
        )
    console.print(table)

    counts = {
        status: sum(result.status == status for result in results) for status in Status
    }
    if counts[Status.FAIL]:
        headline, style = "ACTION NEEDED", "bold red"
    elif counts[Status.WARN]:
        headline, style = "HEALTHY WITH WARNINGS", "bold yellow"
    else:
        headline, style = "HEALTHY", "bold green"
    summary = f"{headline}: {counts[Status.PASS]} passed, {counts[Status.WARN]} warning(s), {counts[Status.FAIL]} failed, {counts[Status.SKIP]} skipped"
    console.print(
        Panel(
            Text(summary, style=style),
            title="Overall summary",
            border_style=style.split()[-1],
        )
    )


def main() -> int:
    """Run all health checks and return a non-zero code only for failures."""

    parser = argparse.ArgumentParser(
        description="Check local Walmart ETL project health."
    )
    parser.add_argument(
        "--quick",
        action="store_true",
        help="Skip starting a temporary local PySpark session.",
    )
    args = parser.parse_args()
    load_dotenv(PROJECT_ROOT / ".env")

    results = [
        check_postgres(),
        check_mongo(),
        check_pyspark(args.quick),
        check_docker(),
        check_compose_services(),
        check_airflow(),
        check_pipeline_run(),
        check_git(),
    ]
    render_report(results)
    return 1 if any(result.status == Status.FAIL for result in results) else 0


if __name__ == "__main__":
    raise SystemExit(main())
