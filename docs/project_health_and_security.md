# Project Health and Security Checks

This project includes two local, read-only checks that provide a quick view of
the pipeline's operational readiness and security baseline. Run them from the
project root with `uv`.

```powershell
uv run python health_check.py
uv run python security_check.py
```

Both scripts use Rich for a clear terminal report and return a non-zero exit
code when a blocking problem is found. This makes them useful before running
the pipeline and in CI.

## `health_check.py`

`health_check.py` verifies that the local pipeline environment is ready to
run. It checks:

- Postgres and MongoDB connectivity with real ping/query requests
- PySpark version, connector jar availability, and a temporary local Spark job
- Docker daemon availability and Docker Compose service status
- Airflow's local health endpoint
- The result of the latest `run_pipeline.ps1` execution from its pipeline log
- The latest Git commit and whether the working tree has uncommitted changes

Use the faster dependency-only Spark check when needed:

```powershell
uv run python health_check.py --quick
```

This check helps catch stopped services, broken credentials, missing Spark
setup, and incomplete pipeline runs before an ETL job fails partway through.

## `security_check.py`

`security_check.py` scans Git-visible project files without printing any
credential values. It checks for:

- Common API tokens, private keys, embedded database passwords, and hard-coded
  secret assignments
- Sensitive files accidentally tracked by Git
- `.env` protection in `.gitignore` and `.dockerignore`
- Insecure Airflow default credentials
- Docker images that run as root
- Presence of `uv.lock` and security scanning in CI workflows

The report shows only a file path and line number for a finding. Active
credentials are failures; commented example connection strings are warnings,
because they are not live secrets but should never be copied into production.

This check prevents accidental credential commits and highlights configuration
choices that should be hardened before deployment.
