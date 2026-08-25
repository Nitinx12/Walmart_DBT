"""Cross-platform, Docker-safe equivalent of ps1/run_pipeline.ps1.

Pure orchestration only: every stage shells out to the same
scripts/*.py, dbt, and uv commands the PowerShell script calls. It
does not re-implement any extract/transform logic itself.

Stage structure intentionally mirrors run_pipeline.ps1 exactly:
    0. Preflight        (pyspark <-> mongo-spark-connector version check)
    1. Extract          (scripts/extract.py)
    2. Bronze SQL tests (tests/bronze/*.sql)
    3. dbt silver build + test (walmart_dbt, models/silver)  -- one stage
    4. Silver SQL tests (tests/silver/*.sql)
    5. dbt gold build + test (walmart_dbt, models/gold)      -- one stage
    6. Gold SQL tests (tests/gold/*.sql)
Stops immediately on the first failed stage.
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent
DBT_PROJECT_DIR = PROJECT_ROOT / "walmart_dbt"
LOG_DIR = PROJECT_ROOT / "logs"
ENV_FILE = PROJECT_ROOT / ".env"

REQUIRED_PYSPARK_PREFIX = "3.5"
REQUIRED_PYSPARK_VERSION = "3.5.5"

TOTAL_STEPS = 6  # matches run_pipeline.ps1's "STEP n / 6" numbering


def in_container() -> bool:
    """Best-effort 'are we inside a container' check.

    /.dockerenv is set by classic `docker run`/compose but NOT by every
    runtime (e.g. Kubernetes pods usually don't have it). Set
    RUNNING_IN_DOCKER=1 as an ENV line in the Dockerfile for a reliable
    signal regardless of how the image ends up being run.
    """
    return os.environ.get("RUNNING_IN_DOCKER") == "1" or Path("/.dockerenv").exists()


def load_dotenv(path: Path = ENV_FILE) -> None:
    """Load key=value pairs from .env, mirroring Import-DotEnv in the ps1.

    Unlike the ps1 (which overwrites unconditionally), values already
    present in the environment are left alone -- so env vars injected by
    docker-compose's `environment:`/`env_file:` always win over a stray
    local .env baked or mounted into the image.
    """
    if not path.exists():
        print(f"WARNING: {path} not found at project root.")
        return

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip())


def log_line(level: str, message: str) -> None:
    """Append one line to logs/pipeline_YYYY-MM-DD.log (Write-PipelineLog).

    Best-effort: a missing/read-only log volume shouldn't take down
    the pipeline itself.
    """
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        log_file = LOG_DIR / f"pipeline_{datetime.now():%Y-%m-%d}.log"
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with log_file.open("a", encoding="utf-8") as fh:
            fh.write(f"{timestamp} | {level:<8} | pipeline | {message}\n")
    except OSError as exc:
        print(f"WARNING: could not write to log file: {exc}")


@dataclass
class Stage:
    name: str               # short key used in the summary table (matches ps1)
    header: str             # descriptive text shown in the "STEP n/6" banner
    commands: list[list[str]]
    cwd: Path = PROJECT_ROOT


def run_command(command: list[str], cwd: Path) -> None:
    result = subprocess.run(command, cwd=cwd, check=False)
    if result.returncode != 0:
        raise RuntimeError(
            f"Command failed with exit code {result.returncode}: {' '.join(command)}"
        )


def run_stage(stage: Stage) -> None:
    """Run a stage's commands in order, stopping at the first failure.

    For the dbt stages this means `dbt test` is only attempted if
    `dbt run` succeeded -- same as the ps1's Silver/Gold blocks -- and
    both commands still count as a single PASS/FAIL row.
    """
    for command in stage.commands:
        run_command(command, stage.cwd)


def print_stage_header(step: int, total: int, title: str) -> None:
    divider = "-" * 60
    print()
    print(divider)
    print(f" STEP {step} / {total}  -  {title}")
    print(divider)
    log_line("INFO", title)


def preflight() -> None:
    print_stage_header(0, TOTAL_STEPS, "PREFLIGHT (dependency check)")

    result = subprocess.run(
        ["uv", "run", "python", "-c", "import pyspark; print(pyspark.__version__)"],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    installed_version = result.stdout.strip()
    version_ok = installed_version.startswith(REQUIRED_PYSPARK_PREFIX)

    if not version_ok:
        problem = (
            "pyspark not found or failed to import"
            if not installed_version
            else f"pyspark {installed_version} detected, but the Mongo Spark "
            f"Connector requires {REQUIRED_PYSPARK_PREFIX}.x"
        )

        if in_container():
            # Inside a built image the version is supposed to already be
            # pinned by the Dockerfile/lockfile. Mutating dependencies at
            # container runtime needs network access and a writable
            # filesystem that production containers may not have, and it
            # hides a build-time bug instead of surfacing it -- fail fast.
            log_line("ERROR", f"Preflight failed inside container: {problem}")
            raise RuntimeError(
                f"{problem}. Fix the pyspark pin in the Docker image instead "
                "of patching it at container runtime."
            )

        print(f"{problem}. Installing {REQUIRED_PYSPARK_VERSION}...")
        log_line("WARNING", f"{problem}; installing {REQUIRED_PYSPARK_VERSION}")
        run_command(["uv", "add", f"pyspark=={REQUIRED_PYSPARK_VERSION}"], PROJECT_ROOT)

    print(f"[PASS] Preflight completed (pyspark {REQUIRED_PYSPARK_PREFIX}.x)")
    log_line("INFO", f"Preflight passed: pyspark version OK ({REQUIRED_PYSPARK_PREFIX}.x)")


def main() -> int:
    # Force line-buffering even when stdout is piped (Docker logs, CI
    # runners) so stage headers show up in real time instead of only
    # flushing when the process exits.
    sys.stdout.reconfigure(line_buffering=True)

    load_dotenv()
    os.environ.setdefault("PYTHONPATH", str(PROJECT_ROOT))
    os.environ.setdefault("PYTHONIOENCODING", "utf-8")

    start_time = time.perf_counter()

    stages = [
        Stage(
            "Extract",
            "EXTRACT (scripts/extract.py)",
            [["uv", "run", "python", "scripts/extract.py"]],
        ),
        Stage(
            "Bronze Tests",
            "BRONZE SQL TESTS (tests/bronze)",
            [["uv", "run", "python", "scripts/sql_test.py", "tests/bronze"]],
        ),
        Stage(
            "Silver dbt",
            "DBT SILVER (walmart_dbt)",
            [
                ["uv", "run", "dbt", "run", "--select", "silver"],
                ["uv", "run", "dbt", "test", "--select", "silver"],
            ],
            cwd=DBT_PROJECT_DIR,
        ),
        Stage(
            "Silver Tests",
            "SILVER SQL TESTS (tests/silver)",
            [["uv", "run", "python", "scripts/sql_test.py", "tests/silver"]],
        ),
        Stage(
            "Gold dbt",
            "DBT GOLD (walmart_dbt)",
            [
                ["uv", "run", "dbt", "run", "--select", "gold"],
                ["uv", "run", "dbt", "test", "--select", "gold"],
            ],
            cwd=DBT_PROJECT_DIR,
        ),
        Stage(
            "Gold Tests",
            "GOLD SQL TESTS (tests/gold)",
            [["uv", "run", "python", "scripts/sql_test.py", "tests/gold"]],
        ),
    ]

    assert len(stages) == TOTAL_STEPS  # keep header numbering honest

    stage_results: list[tuple[str, str]] = []

    try:
        preflight()
        stage_results.append(("Preflight", "PASS"))

        for index, stage in enumerate(stages, start=1):
            print_stage_header(index, TOTAL_STEPS, stage.header)

            try:
                run_stage(stage)
            except RuntimeError:
                stage_results.append((stage.name, "FAIL"))
                print(f"[FAIL] {stage.name} failed. Stopping pipeline.")
                log_line("ERROR", f"{stage.name} failed - stopping pipeline.")
                raise

            stage_results.append((stage.name, "PASS"))
            print(f"[PASS] {stage.name}")
            log_line("INFO", f"PASS - {stage.name}")

    except Exception as exc:
        print()
        print("=" * 60)
        print(" PIPELINE FAILED")
        print("=" * 60)

        for name, status in stage_results:
            print(f" {name:<25} {status}")

        print("=" * 60)
        print(f"Error: {exc}")

        return 1

    elapsed = time.perf_counter() - start_time

    print()
    print("=" * 60)
    print(" PIPELINE SUMMARY")
    print("=" * 60)

    for name, status in stage_results:
        print(f" {name:<25} {status}")

    print("=" * 60)
    print(f"PIPELINE COMPLETED SUCCESSFULLY in {elapsed:.2f} seconds")
    log_line("INFO", "Pipeline completed successfully")

    return 0


if __name__ == "__main__":
    sys.exit(main())