![dbt](https://img.shields.io/badge/dbt-core-FF694B?logo=dbt&logoColor=white)
![Airflow](https://img.shields.io/badge/Apache%20Airflow-3.3.0-017CEE?logo=apacheairflow&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-4169E1?logo=postgresql&logoColor=white)
![PySpark](https://img.shields.io/badge/PySpark-3.5.x-E25A1C?logo=apachespark&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)
![CI/CD](https://img.shields.io/badge/CI%2FCD-in%20progress-FFC107?logo=githubactions&logoColor=white)

# Walmart Medallion Data Pipeline

**MongoDB → PostgreSQL → dbt** pipeline that turns raw sales data into a
tested, dimensional warehouse orchestrated with **Airflow**, containerized
with **Docker**, and runnable locally with **PowerShell**.

<img width="1536" height="1024" alt="image" src="https://github.com/user-attachments/assets/c8f1afcc-9b53-4771-a4b5-2b730ea2354e" />


## What it demonstrates

- **PySpark** incremental extraction from MongoDB (watermark-based, no full re-loads)
- **dbt** — 17 models (9 silver + 8 gold), 100+ tests, SCD Type 2 snapshots
- **Airflow 3.x** DAG orchestrating the full 7-stage pipeline
- **Docker Compose** stack (CeleryExecutor) + standalone container image
- **PowerShell** automation script with a data-quality gate
- Independent SQL test suite as a second layer of data-quality checks
- **GitHub Actions CI/CD** *(in progress)* — lint, DAG-integrity checks, and
  a full bronze → silver → gold integration run against a live Postgres
  service container on every PR, with Docker images published to GHCR on
  merge. See [`docs/ci_cd.md`](docs/ci_cd.md).

## Tech stack

`Python` · `PySpark` · `dbt-core` · `PostgreSQL` · `MongoDB` · `Apache Airflow` · `Docker` · `PowerShell` · `uv`

## Full documentation

This is a quick overview only. Full architecture, setup steps, and
per-module deep dives are in the repo:

- [`README.md`](README.md) — complete write-up
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — full system design
- [`docs/`](docs/) — dbt, Airflow, Docker, and pipeline internals

## Full PowerShell pipeline script

📄 **[View `run_pipeline.ps1` on Google Drive](https://drive.google.com/file/d/1vSPYN8GvC5cFMEHf7EVjwSq4HHAbCZRF/view?usp=sharing)**

---

📧 Reach out if you'd like a walkthrough of any part of this project.