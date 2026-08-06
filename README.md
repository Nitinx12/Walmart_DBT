![Airflow](https://img.shields.io/badge/Apache%20Airflow-3.3.0-017CEE?logo=apacheairflow&logoColor=white)
![dbt](https://img.shields.io/badge/dbt-core-FF694B?logo=dbt&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-4169E1?logo=postgresql&logoColor=white)
![MongoDB](https://img.shields.io/badge/MongoDB-source-47A248?logo=mongodb&logoColor=white)
![PySpark](https://img.shields.io/badge/PySpark-3.5.x-E25A1C?logo=apachespark&logoColor=white)
![Medallion](https://img.shields.io/badge/Architecture-Medallion-D4AF37)

# Walmart Medallion Data Pipeline

A production-style **MongoDB → PostgreSQL → dbt** pipeline: incremental PySpark extraction, a tested medallion warehouse (bronze → silver → gold), orchestrated with **Airflow**, containerized with **Docker**, and gated by two independent layers of data-quality checks at every handoff.

Built to mirror how a real analytics-engineering team would ship this — not a notebook demo.

## Architecture at a glance

```mermaid
flowchart LR
    MONGO[("MongoDB<br/>operational source")] -->|"PySpark, watermark-based<br/>incremental extract"| BRONZE

    subgraph PG["PostgreSQL — walmart_db"]
        BRONZE[("bronze<br/>raw, 1:1 with Mongo")]
        SILVER[("silver<br/>deduped, typed, SCD2")]
        GOLD[("gold<br/>dimensional star/snowflake")]
        BRONZE -->|"dbt + SQL tests"| SILVER
        SILVER -->|"dbt + SQL tests"| GOLD
    end

    GOLD --> BI["reports/<br/>brand & category analysis"]

    classDef bronze fill:#CD7F32,color:#fff,stroke:#8b5a2b
    classDef silver fill:#C0C0C0,color:#1a1a1a,stroke:#888888
    classDef gold fill:#D4AF37,color:#1a1a1a,stroke:#8a6d1f
    class BRONZE bronze
    class SILVER silver
    class GOLD gold
```

Every arrow into silver and gold is a **quality gate**, not a formality — the next layer only builds if the prior layer's tests pass. Full breakdown: [`ARCHITECTURE.md`](ARCHITECTURE.md) §4.

## Orchestration — one pipeline, run three ways

The same 7 stages run locally via PowerShell, in a standalone Docker image, or on a schedule in Airflow:

```mermaid
flowchart TD
    S0["0 · Preflight"] --> S1["1 · Extract<br/>Mongo → bronze"]
    S1 --> S2["2 · Bronze SQL tests"]
    S2 --> S3["3 · dbt run + test — silver"]
    S3 --> S4["4 · Silver SQL tests"]
    S4 --> S5["5 · dbt run + test — gold"]
    S5 --> S6["6 · Gold SQL tests"]

    classDef stage fill:#1a2a3a,color:#fff,stroke:#4a90d9
    class S0,S1,S2,S3,S4,S5,S6 stage
```

In Airflow this is `walmart_medallion_pipeline`, with `all_success` trigger rules stopping the DAG the moment any stage fails. Full DAG + task-by-task detail: [`docs/airflow.md`](docs/airflow.md).

## Highlights

| Area | What's there |
|---|---|
| **Incremental extraction** | Watermark-based `$gt` pushdown from Mongo, real `MERGE`-style upserts, automatic fallback when no watermark or unique index exists |
| **Modeling** | 17 dbt models (9 silver + 8 gold), 100+ tests, SCD Type 2 snapshots |
| **Data quality** | Two independent QA layers — dbt-native tests *and* a standalone schema-driven SQL suite — wired in as separate pipeline stages |
| **Runners** | Windows/PowerShell, standalone Docker image, Airflow DAG — all executing the identical 7 stages |
| **Containerization** | Docker Compose stack (CeleryExecutor: scheduler, workers, triggerer, Redis) plus a self-contained pipeline image |
| **CI/CD** *(in progress)* | Lint, DAG-integrity checks, and a live bronze→silver→gold run against Postgres on every PR; images published to GHCR on merge — [`docs/ci_cd.md`](docs/ci_cd.md) |

## Tech stack

`Python` · `PySpark` · `dbt-core` · `PostgreSQL` · `MongoDB` · `Apache Airflow` · `Docker` · `PowerShell` · `uv`

## Run it

```powershell
# Local, Windows
./pipeline/run_pipeline.ps1

# Standalone container
docker run --env-file .env walmart-pipeline

# Full Airflow stack
docker compose -f docker/docker-compose.yaml up
```

## Full documentation

This README is the pitch. Everything below is the engineering detail:

| Doc | Covers |
|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Full system design — every diagram above, expanded |
| [`docs/airflow.md`](docs/airflow.md) | The DAG, task by task |
| [`docs/dbt.md`](docs/dbt.md) | Models, grain, SCD types, tests |
| [`docs/docker.md`](docs/docker.md) | Both images, why two, build details |
| [`docs/pipeline.md`](docs/pipeline.md) | The PowerShell entry point |
| [`docs/scripts.md`](docs/scripts.md) | `extract.py`'s incremental vs. full-reload logic |
| [`docs/tests.md`](docs/tests.md) | What the raw SQL checks actually check |
| [`docs/utils.md`](docs/utils.md) | Shared config/connection/logging |

Full pipeline script (`run_pipeline.ps1`): [view on Google Drive](https://drive.google.com/file/d/1vSPYN8GvC5cFMEHf7EVjwSq4HHAbCZRF/view?usp=sharing)

📧 Reach out if you'd like a walkthrough of any part of this project.