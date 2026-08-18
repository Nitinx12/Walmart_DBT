# AGENTS.md

Guide for AI agents and humans working on this repo. For the full system
design, read `ARCHITECTURE.md` first — this file only covers day-to-day
conventions: setup, coding style, and git workflow.

## Project Overview
- medallion-architecture ETL pipeline: MongoDB (source) → Postgres
  bronze → silver → gold, validated by dbt tests + raw SQL checks
- one logical pipeline, three runners: `pipeline/run_pipeline.ps1`
  (Windows host), standalone Docker image (`main.py`), Airflow DAG
- package manager: uv (see `pyproject.toml` / `uv.lock`)

## Environment Setup — uv
```bash
# create virtual environment
uv venv

# activate (Windows)
.venv\Scripts\activate
# activate (linux/mac/devcontainer)
source .venv/bin/activate

# install locked dependencies
uv sync

# add a runtime dependency
uv add package_name

# add a dev-only dependency
uv add --dev pytest ruff

# run any script through uv instead of the bare interpreter
uv run python scripts/extract.py
uv run python scripts/sql_test.py tests/bronze
```
`uv.lock` is the source of truth — never hand-edit dependency versions
in `pyproject.toml` without running `uv lock` afterward.

## Dev Container
```
.devcontainer/devcontainer.json
```
- open in VS Code → "Reopen in Container" (or GitHub Codespaces)
- image mirrors `docker/Dockerfile`: JDK 17 + `uv` preinstalled, so
  PySpark works out of the box — no local Java setup needed
- on first attach, run `uv sync` to materialize `.venv` inside the
  container from `uv.lock`
- postgres/mongo are reached via `host.docker.internal`, same
  correction every other container needs (see `ARCHITECTURE.md` §7,
  the "localhost problem") — never edit `.env` itself for this
- always run project commands as `uv run <cmd>` inside the container
  terminal; don't `pip install` directly, it won't update `uv.lock`
- code is bind-mounted, so edits on the host show up in the container
  immediately — no rebuild needed for Python changes

## Repository Structure
```
airflow/        # dags/walmart_pipeline_dag.py + bind-mounted logs/plugins
docker/         # Dockerfile, Dockerfile.airflow, docker-compose.yaml, entrypoint.sh
docs/           # deep-dive docs: airflow.md, dbt.md, docker.md, pipeline.md, scripts.md, tests.md, utils.md
jars/           # Mongo Spark connector + Postgres JDBC, checked in for offline Spark startup
pipeline/       # run_pipeline.ps1 — Windows entry point
scripts/        # extract.py (Mongo -> bronze), sql_test.py (SQL test runner)
sql/            # hand-written functions/triggers/reports
tests/          # standalone SQL data-quality suite, one folder per layer
utils/          # engine.py, connection.py, logger.py — shared infra
walmart_dbt/    # dbt project: silver + gold models, schema tests
reports/        # generated markdown reports + chart PNGs
main.py         # entry point for the standalone Docker image
```

## Coding Conventions
- snake_case for variables, functions, filenames, dbt model names
- comments short and meaningful — explain *why*, not *what*
- type hints on every function signature; docstring on every public one
- one function = one responsibility (see `extract.py`'s stage split as
  the reference pattern)
- run `uv run ruff format .` and `uv run ruff check .` before committing

Example:
```python
def sanitize_for_postgres(doc: dict) -> dict:
    # Postgres has no BSON ObjectId type, so cast _id to string early
    doc["_id"] = str(doc["_id"])
    return doc
```

## Pipeline Stage Rule
The pipeline has 7 fixed stages (preflight → extract → bronze tests →
dbt silver → silver tests → dbt gold → gold tests), run identically by
all three runners. **If you change the stage order, add a stage, or
redefine "success," update `run_pipeline.ps1` AND the Airflow DAG in the
same change** — nothing enforces this automatically, it's a convention.

## Testing
Two independent, non-overlapping test systems — don't conflate them:
```bash
# dbt-native tests (schema.yml column/table checks)
uv run dbt test --select silver
uv run dbt test --select gold

# standalone SQL data-quality suite (schema-driven PL/pgSQL checks)
uv run python scripts/sql_test.py tests/silver
```
- every new dbt model needs schema.yml tests
- every new extract/transform function needs at least one unit test
- use small fixture data, never real Mongo/Postgres data, in tests

## Git Workflow
Work on one file or one logical change at a time.
```bash
# stage only the file you edited
git add scripts/extract.py

# commit with a clear, meaningful message
git commit -m "extract: fall back to append-only when no unique index"
```
Commit message rules:
- present tense, short summary (<= 50 chars)
- prefix by area: `extract:`, `dbt:`, `airflow:`, `docker:`, `tests:`,
  `utils:`, `docs:`
- add a body line for *why*, if not obvious:
```bash
git commit -m "docker: pin JDK to 17" \
  -m "PySpark 3.5.x mongo connector is untested on JDK 21"
```
- one commit = one file/change, unless files are inseparable (a model
  and its schema.yml test, a function and its test)
- pull before starting new work: `git pull --rebase`

## Do / Don't for Agents
- do keep `.env` untouched — container-specific host corrections belong
  in the consuming layer (DAG `_PREAMBLE`, `docker run` flags), never in
  `.env` itself
- do auto-discover Mongo collections; never hardcode a collection list
- do run `uv run pytest` and the SQL suite before committing pipeline
  changes
- don't commit `.venv`, `__pycache__`, `.env`, or anything under
  `data/raw` or `data/processed`
- don't bundle unrelated changes (e.g. a dbt model fix + a Dockerfile
  bump) into one commit
- don't rewrite working stage logic without being asked

## Quick Reference
| Task | Command |
|---|---|
| create env | `uv venv` |
| install deps | `uv sync` |
| add dependency | `uv add <pkg>` |
| run extract | `uv run python scripts/extract.py` |
| run dbt tests | `uv run dbt test --select silver` |
| run SQL suite | `uv run python scripts/sql_test.py tests/<layer>` |
| format code | `uv run ruff format .` |
| lint code | `uv run ruff check .` |
| stage one file | `git add <file>` |
| commit | `git commit -m "<area>: <summary>"` |