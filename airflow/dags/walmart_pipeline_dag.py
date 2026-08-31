"""
walmart_pipeline_dag.py
Target location in your repo: airflow/dags/walmart_pipeline_dag.py

Mirrors pipeline/run_pipeline.ps1 stage-for-stage and in the same order:
    0. Preflight        (pyspark <-> mongo-spark-connector version check)
    1. Extract          (scripts/extract.py)
    2. Bronze SQL tests (tests/bronze/*.sql)
    3. dbt silver build + test (walmart_dbt, models/silver)
    4. Silver SQL tests (tests/silver/*.sql)
    5. dbt gold build + test (walmart_dbt, models/gold)
    6. Gold SQL tests (tests/gold/*.sql)
    7. Great Expectations tests (Bronze, Silver, Gold)

Stop-on-first-failure is native to this: Airflow's default trigger rule
(all_success) means the moment one task fails, everything downstream goes
to upstream_failed and never runs -- no extra guard logic needed to match
ps1's Stop-Pipeline behavior.
"""

from __future__ import annotations

import pendulum
from airflow.sdk import dag, task

# Adjust if your Airflow worker image mounts the walmart repo elsewhere.
# ps1's own comment says this mirrors `ENV PYTHONPATH=/app` in docker/Dockerfile.
PROJECT_ROOT = "/app"
DBT_PROJECT_DIR = f"{PROJECT_ROOT}/walmart_dbt"

REQUIRED_PYSPARK_PREFIX = "3.5"

# BashOperator/@task.bash does not auto-load .env the way ps1's Import-DotEnv
# does, so every task sources it explicitly. Silently no-ops if missing,
# same as ps1's WARNING-only behavior on a missing file.
#
# .env is shared with local Windows runs (run_pipeline.ps1) and is NOT
# edited for container use -- it points Postgres/Mongo at "localhost" and
# PySpark at a Windows .venv, none of which resolve correctly from inside
# this container. Instead of touching .env (other files depend on it as-is),
# override those specific values here, after sourcing, so only the
# Airflow-container execution path is affected:
#   - POSTGRES_HOST / MONGO_URI: "localhost" -> "host.docker.internal",
#     since Postgres/Mongo run on the host machine, not in this compose
#     stack. Uses shell substitution so it's a no-op if .env ever points
#     elsewhere (e.g. a real remote host) instead of localhost.
#   - PYSPARK_PYTHON / PYSPARK_DRIVER_PYTHON: forced to the container's own
#     venv (matches Dockerfile.airflow's ENV, which .env sourcing would
#     otherwise clobber with the Windows path).
#   - DBT_PROFILES_DIR: dbt defaults to ~/.dbt, which doesn't exist in this
#     container and, even mounted, would expose unrelated projects' creds
#     from the global profiles.yml. Points instead at a project-scoped
#     profiles.yml (docker/dbt/profiles.yml) containing only the
#     walmart_dbt entry, bind-mounted in automatically since it lives
#     under /app.
_PREAMBLE = (
    "set -euo pipefail; "
    f"cd {PROJECT_ROOT}; "
    f'if [ -f "{PROJECT_ROOT}/.env" ]; then set -a; source "{PROJECT_ROOT}/.env"; set +a; fi; '
    'export POSTGRES_HOST="${POSTGRES_HOST/localhost/host.docker.internal}"; '
    'export MONGO_URI="${MONGO_URI//localhost/host.docker.internal}"; '
    f"export PYTHONPATH={PROJECT_ROOT}; "
    "export PYSPARK_PYTHON=/app/.venv/bin/python; "
    "export PYSPARK_DRIVER_PYTHON=/app/.venv/bin/python; "
    f"export DBT_PROFILES_DIR={PROJECT_ROOT}/docker/dbt; "
)


@dag(
    dag_id="walmart_medallion_pipeline",
    schedule=None,
    start_date=pendulum.datetime(2026, 1, 1, tz="UTC"),
    catchup=False,
    max_active_runs=1,
    tags=["walmart", "medallion", "elt"],
    default_args={"retries": 0},
)
def walmart_medallion_pipeline():

    @task.bash(task_id="preflight")
    def preflight() -> str:
        return _PREAMBLE + (
            'installed="$(uv run python -c '
            "'import pyspark; print(pyspark.__version__)' 2>/dev/null || true)\"; "
            f'if [[ "$installed" != {REQUIRED_PYSPARK_PREFIX}* ]]; then '
            f'echo "pyspark $installed is incompatible; run uv sync to restore '
            f'{REQUIRED_PYSPARK_PREFIX}.x"; exit 1; '
            f'else echo "pyspark $installed OK"; fi'
        )

    @task.bash(task_id="extract")
    def extract() -> str:
        return _PREAMBLE + "uv run python scripts/extract.py"

    @task.bash(task_id="bronze_sql_tests")
    def bronze_sql_tests() -> str:
        return _PREAMBLE + "uv run python scripts/sql_test.py tests/bronze"

    @task.bash(task_id="dbt_silver_run")
    def dbt_silver_run() -> str:
        return _PREAMBLE + f"cd {DBT_PROJECT_DIR} && uv run dbt run --select silver"

    @task.bash(task_id="dbt_silver_test")
    def dbt_silver_test() -> str:
        return _PREAMBLE + f"cd {DBT_PROJECT_DIR} && uv run dbt test --select silver"

    @task.bash(task_id="silver_sql_tests")
    def silver_sql_tests() -> str:
        return _PREAMBLE + "uv run python scripts/sql_test.py tests/silver"

    @task.bash(task_id="dbt_gold_run")
    def dbt_gold_run() -> str:
        return _PREAMBLE + f"cd {DBT_PROJECT_DIR} && uv run dbt run --select gold"

    @task.bash(task_id="dbt_gold_test")
    def dbt_gold_test() -> str:
        return _PREAMBLE + f"cd {DBT_PROJECT_DIR} && uv run dbt test --select gold"

    @task.bash(task_id="gold_sql_tests")
    def gold_sql_tests() -> str:
        return _PREAMBLE + "uv run python scripts/sql_test.py tests/gold"

    @task.bash(task_id="great_expectations_tests")
    def great_expectations_tests() -> str:
        return _PREAMBLE + "uv run python -m pipeline.data_quality.run --layer all"

    (
        preflight()
        >> extract()
        >> bronze_sql_tests()
        >> dbt_silver_run()
        >> dbt_silver_test()
        >> silver_sql_tests()
        >> dbt_gold_run()
        >> dbt_gold_test()
        >> gold_sql_tests()
        >> great_expectations_tests()
    )


walmart_medallion_pipeline()
