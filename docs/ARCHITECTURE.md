![Airflow](https://img.shields.io/badge/Apache%20Airflow-3.3.0-017CEE?logo=apacheairflow&logoColor=white)
![dbt](https://img.shields.io/badge/dbt-core-FF694B?logo=dbt&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-4169E1?logo=postgresql&logoColor=white)
![MongoDB](https://img.shields.io/badge/MongoDB-source-47A248?logo=mongodb&logoColor=white)
![PySpark](https://img.shields.io/badge/PySpark-3.5.x-E25A1C?logo=apachespark&logoColor=white)
![Medallion](https://img.shields.io/badge/Architecture-Medallion-D4AF37)

# Architecture — Walmart Medallion Pipeline

This is the single map of the system: what it is, how data moves through
it, how one seven-stage pipeline runs three different ways (a Windows
script, a standalone Docker image, and an Airflow DAG), and how the
supporting pieces — `utils/`, `docker/`, `walmart_dbt/`, `tests/` — fit
around that core. Every section links out to the doc that covers it in
full; this file is the overview, not a replacement for `docs/*.md`.

## Contents

1. [System overview](#1-system-overview)
2. [Three runners, one pipeline](#2-three-runners-one-pipeline)
3. [Runtime topology](#3-runtime-topology--whats-actually-running-where)
4. [The medallion layers, and what gates each transition](#4-the-medallion-layers-and-what-gates-each-transition)
5. [Two independent test systems](#5-two-independent-test-systems--dont-conflate-them)
6. [Two Docker images, two jobs](#6-two-docker-images-two-jobs)
7. [The `localhost` problem, solved once, applied twice](#7-the-localhost-problem-solved-once-applied-twice)
8. [The `extract.py` decision engine](#8-the-extractpy-decision-engine)
9. [Shared infrastructure — `utils/`](#9-shared-infrastructure--utils)
10. [Repository layout](#10-repository-layout)
11. [Where to go next](#11-where-to-go-next)

---

## 1. System overview

A **medallion-architecture ETL pipeline**: it pulls operational data out
of MongoDB, lands it as raw bronze tables in Postgres, cleans and
deduplicates it into silver, and reshapes it into a dimensional gold
layer — validated by SQL checks and dbt tests at every handoff, and
runnable directly on Windows, as a standalone Docker container, or
orchestrated by Airflow.

```mermaid
flowchart LR
    MONGO[("MongoDB<br/>operational source")] -->|"scripts/extract.py<br/>PySpark + Mongo connector"| BRONZE

    subgraph PG["PostgreSQL — walmart_db"]
        BRONZE[("bronze schema<br/>raw, 1:1 with Mongo collections")]
        SILVER[("silver schema<br/>deduped, typed, normalized")]
        GOLD[("gold schema<br/>dimensional star/snowflake")]
        BRONZE -->|"dbt run --select silver"| SILVER
        SILVER -->|"dbt run --select gold"| GOLD
    end

    GOLD --> BI["reports/<br/>brand_report.md, category_report.md,<br/>charts/"]

    classDef bronze fill:#CD7F32,color:#fff,stroke:#8b5a2b
    classDef silver fill:#C0C0C0,color:#1a1a1a,stroke:#888888
    classDef gold fill:#D4AF37,color:#1a1a1a,stroke:#8a6d1f
    class BRONZE bronze
    class SILVER silver
    class GOLD gold
```

Every layer is guarded by its own tests before the next layer is allowed
to build from it — see [§4](#4-the-medallion-layers-and-what-gates-each-transition).

---

## 2. Three runners, one pipeline

The project deliberately exposes **one logical pipeline through three
separate entry points**. They aren't three different pipelines — they're
three runners for the same seven stages, kept in lockstep by convention.

```mermaid
flowchart TD
    subgraph Entry["Entry points"]
        WIN["pipeline/run_pipeline.ps1<br/>local, interactive, Windows"]
        DOCK["docker run walmart-pipeline<br/>standalone container, main.py"]
        AF["Airflow DAG<br/>walmart_medallion_pipeline<br/>scheduled / containerized"]
    end

    WIN --> STAGES
    DOCK --> STAGES
    AF --> STAGES

    subgraph STAGES["Same 7 stages, in order"]
        direction TB
        S0["0. Preflight — pyspark/mongo-connector version check"]
        S1["1. Extract — Mongo → bronze"]
        S2["2. Bronze SQL tests"]
        S3["3. dbt silver (run + test)"]
        S4["4. Silver SQL tests"]
        S5["5. dbt gold (run + test)"]
        S6["6. Gold SQL tests"]
        S0-->S1-->S2-->S3-->S4-->S5-->S6
    end
```

| | `run_pipeline.ps1` | Standalone `docker run` | Airflow DAG |
|---|---|---|---|
| **Where it runs** | Directly on the Windows host | Any Docker host, self-contained image | `airflow-worker` container in the compose stack |
| **Stop-on-failure** | Manual — every stage checks `$LASTEXITCODE`, calls `Stop-Pipeline` | Same script logic, inside the container's `main.py`/entrypoint chain | Automatic — Airflow's default `all_success` trigger rule |
| **`.env` loading** | `Import-DotEnv` — custom line-by-line PowerShell parser | `--env-file .env` passed to `docker run` | `source .env` inside each task's shell, via the DAG's `_PREAMBLE` |
| **`localhost` correctness** | Correct as-is — runs on the host | Corrected via env vars passed at `docker run` time | Rewritten to `host.docker.internal` in `_PREAMBLE` |
| **Code delivery** | Already on disk | Baked in at build time (`COPY . .`) | Bind-mounted (`../..:/app`), no rebuild for code changes |
| **Full detail** | [`docs/pipeline.md`](docs/pipeline.md) | [`docs/docker.md`](docs/docker.md) §4, §6–7 | [`docs/airflow.md`](docs/airflow.md) |

**The rule that keeps all three honest:** changing the stage order,
adding a stage, or redefining "success" for one means updating the
Windows script *and* the DAG. Nothing enforces this automatically — it's
a documented convention, not a technical guarantee.

---

## 3. Runtime topology — what's actually running where

```mermaid
flowchart TB
    subgraph Host["Host machine"]
        USER["You — browser<br/>localhost:8080"]
        HOSTDB[("Postgres<br/>walmart_db<br/>host.docker.internal:5432")]
        HOSTMONGO[("MongoDB<br/>host.docker.internal:27017")]
    end

    subgraph Standalone["Standalone image path"]
        IMG1["walmart-pipeline image<br/>python:3.12-slim + JDK 17 + uv"]
        RUN1["container: entrypoint.sh waits for Postgres,<br/>then exec uv run main.py"]
        IMG1 --> RUN1
    end

    subgraph ComposeStack["docker compose stack (Airflow, CeleryExecutor)"]
        API["airflow-apiserver :8080"]
        SCHED["airflow-scheduler"]
        DAGP["airflow-dag-processor"]
        WORK["airflow-worker<br/>ALL @task.bash commands run here"]
        TRIG["airflow-triggerer"]
        MPG[("postgres<br/>Airflow metadata DB<br/>— NOT walmart_db")]
        REDIS[("redis<br/>Celery broker")]
    end

    USER --> API
    API --> MPG
    SCHED --> MPG
    SCHED -- "queues task" --> REDIS
    DAGP -- "parses DAG files" --> MPG
    REDIS -- "delivers task" --> WORK
    WORK --> MPG
    TRIG --> MPG
    WORK -- "bash task execution" --> HOSTDB
    WORK --> HOSTMONGO
    RUN1 --> HOSTDB
    RUN1 --> HOSTMONGO
```

Two independent images exist because they serve two different purposes
— see [§6](#6-two-docker-images-two-jobs). Only `airflow-worker` ever
executes pipeline logic; every other Airflow service is
scheduling, serving, or metadata machinery. Full breakdown:
[`docs/docker.md`](docs/docker.md) §1, [`docs/airflow.md`](docs/airflow.md) §1.

---

## 4. The medallion layers, and what gates each transition

```mermaid
flowchart TD
    MONGO[("MongoDB collections<br/>auto-discovered, no hardcoded list")]

    subgraph B["BRONZE — raw, 1:1 with source"]
        BX["extract.py: incremental upsert via<br/>watermark + MERGE (INSERT...ON CONFLICT)"]
        BT["3 SQL checks:<br/>tables exist, columns exist, metadata cols populated"]
    end

    subgraph S["SILVER — dedup + type-clean"]
        SM["9 dbt models:<br/>customers, employees, stores, products, orders,<br/>order_items, brands, categories, payment_methods"]
        ST["dbt test --select silver<br/>+ 9 raw SQL checks in tests/silver/"]
    end

    subgraph G["GOLD — dimensional (snowflake schema)"]
        GM["8 dbt models:<br/>7 dims + 1 fact (fact_order_items)"]
        GT["dbt test --select gold<br/>+ 7 raw SQL checks in tests/gold/"]
    end

    MONGO --> BX --> BT -->|"gate: all 3 checks pass"| SM
    SM --> ST -->|"gate: dbt test + 9 checks pass"| GM
    GM --> GT -->|"gate: dbt test + 7 checks pass"| DONE(["pipeline succeeds"])

    classDef bronze fill:#CD7F32,color:#fff,stroke:#8b5a2b
    classDef silver fill:#C0C0C0,color:#1a1a1a,stroke:#888888
    classDef gold fill:#D4AF37,color:#1a1a1a,stroke:#8a6d1f
    class BX,BT bronze
    class SM,ST silver
    class GM,GT gold
```

Each gate is enforced by exit codes, not application logic: a non-zero
exit from any stage stops everything downstream, whether that stage is a
Python script, a `dbt` command, or a raw SQL file. See [§5](#5-two-independent-test-systems--dont-conflate-them)
and [§8](#8-the-extractpy-decision-engine).

### 4.1 The gold layer is a snowflake, not a pure star

`dim_products` and `dim_orders` keep foreign keys to their own
dimensions (`brand_id`/`category_id`, `store_id`/`customer_id`/
`payment_method_id`) rather than denormalizing names inline — so the
fact table only touches two dimensions directly, and those two fan out
one level further:

```mermaid
flowchart TD
    FACT["fact_order_items<br/>grain: one row per order_item_id"]
    DORD["dim_orders"]
    DPROD["dim_products"]
    DCUST["dim_customers"]
    DSTORE["dim_stores"]
    DPAY["dim_payment_methods"]
    DBRAND["dim_brands"]
    DCAT["dim_categories"]

    FACT --> DORD
    FACT --> DPROD
    DORD --> DCUST
    DORD --> DSTORE
    DORD --> DPAY
    DPROD --> DBRAND
    DPROD --> DCAT
```

Full model-by-model grain, SCD type, and test list: [`docs/dbt.md`](docs/dbt.md) §4–5.

---

## 5. Two independent test systems — don't conflate them

The project runs data-quality checks through **two unrelated
mechanisms** that happen to share the word "tests":

```mermaid
flowchart LR
    subgraph DBTT["dbt-native tests"]
        direction TB
        D1["walmart_dbt/models/*/schema.yml<br/>column + table-level tests"]
        D2["3 custom generics in<br/>walmart_dbt/tests/generic/*.sql<br/>(defined but currently unused —<br/>schema.yml uses dbt_utils equivalents instead)"]
        D3["run by: dbt test"]
        D1 --> D3
    end

    subgraph SQLT["standalone SQL test suite"]
        direction TB
        Q1["tests/bronze/*.sql (3)<br/>tests/silver/*.sql (9)<br/>tests/gold/*.sql (7)"]
        Q2["schema-driven PL/pgSQL loops —<br/>discover tables/columns from<br/>information_schema, one rule<br/>applied project-wide"]
        Q3["run by: scripts/sql_test.py"]
        Q1 --> Q2 --> Q3
    end
```

| | dbt tests | Standalone SQL suite |
|---|---|---|
| Defined in | `schema.yml` per model | Individual `.sql` files, one rule each |
| Invoked as | `dbt test --select silver` / `gold` | `uv run python scripts/sql_test.py tests/<layer>` |
| Convention | dbt's own pass/fail semantics | Auto-detected per file: either "SELECT returns violating rows" or "DO block raises an exception" |
| Full detail | [`docs/dbt.md`](docs/dbt.md) | [`docs/tests.md`](docs/tests.md), [`docs/scripts.md`](docs/scripts.md) §2 |

Both are wired into every runner (`run_pipeline.ps1`, the Airflow DAG,
`main.py` inside the standalone container) as separate pipeline stages,
not as a single combined "testing" step.

---

## 6. Two Docker images, two jobs

```mermaid
flowchart TD
    subgraph ctx["Build context: project root"]
        DF["docker/Dockerfile"]
        DFA["docker/Dockerfile.airflow"]
    end

    DF -- "COPY . . (code baked in)<br/>base: python:3.12-slim" --> IMG1["walmart-pipeline<br/>self-contained image"]
    IMG1 -- "docker run --env-file .env" --> RUN1["standalone container<br/>entrypoint.sh waits for Postgres,<br/>then CMD: uv run main.py"]

    DFA -- "base: apache/airflow:3.3.0-python3.11<br/>+ JDK 17, uv" --> IMG2["docker-airflow-* image<br/>nearly empty of project code"]
    IMG2 --> SVC["every airflow-* service"]
    COMPOSE["docker-compose.yaml"] -- "bind mount ../ → /app<br/>(code changes need no rebuild)" --> SVC
```

Both images share the same JDK, `uv` install, and `PYSPARK_*`/`SPARK_*`
env vars, so pipeline behavior is identical regardless of which runner
triggered it — what differs is *how code gets in* (`COPY` vs. bind mount)
and *what needs correcting for a container network* ([§7](#7-the-localhost-problem-solved-once-applied-twice)).
Full rationale, Dockerfile line-by-line: [`docs/docker.md`](docs/docker.md) §1–5.

---

## 7. The `localhost` problem, solved once, applied twice

The single most-repeated theme across every layer of this project:
`.env` is shared between a Windows host (where `localhost` is correct)
and Linux containers (where it isn't) — and the fix is always
**downstream correction, never editing `.env` itself**.

```mermaid
flowchart TD
    ENV[".env — Windows-correct values<br/>POSTGRES_HOST=localhost<br/>MONGO_URI=...localhost:27017<br/>PYSPARK_PYTHON=.venv\\Scripts\\python.exe"]

    ENV -->|"used as-is"| WIN["run_pipeline.ps1<br/>correct: runs on the host directly"]

    ENV -->|"sourced, then corrected<br/>in the DAG's _PREAMBLE"| AF["Airflow @task.bash:<br/>POSTGRES_HOST → host.docker.internal<br/>MONGO_URI host → host.docker.internal<br/>PYSPARK_PYTHON forced to Linux path"]

    ENV -->|"sourced via --env-file,<br/>overridden at docker run time"| STANDALONE["standalone container:<br/>same corrections applied<br/>via docker/.env or docker run flags"]

    style ENV fill:#4a5568,color:#fff
```

Why this design: `.env` is referenced by multiple independent files
(`run_pipeline.ps1` included), so correcting it in place would break the
one context where it's already right. Every container-specific fix
happens in the consuming layer instead. Full mechanics:
[`docs/airflow.md`](docs/airflow.md) §3, [`docs/docker.md`](docs/docker.md) §9.

---

## 8. The `extract.py` decision engine

The most complex single piece of logic in the project — worth its own
diagram since every other stage is comparatively mechanical (`dbt run`,
`dbt test`, or a SQL file).

```mermaid
flowchart TD
    A["sample document,<br/>auto-detect watermark column:<br/>updated_timestamp > updated_at ><br/>created_timestamp > created_at"] --> B{"--full-refresh?"}
    B -- yes --> C["full reload, truncate first"]
    B -- no --> D{"watermark column found?"}
    D -- yes --> E["incremental: $gt pushdown<br/>since last watermark"]
    D -- no --> F["full reload<br/>(no watermark available)"]
    C --> G["sanitize_for_postgres()<br/>_id → string, nested → JSON"]
    E --> G
    F --> G
    G --> H{"table exists +<br/>_id unique index?"}
    H -- yes --> I["staging table + real MERGE<br/>INSERT...ON CONFLICT DO UPDATE<br/>(xmax=0 trick splits insert/update counts)"]
    H -- no --> J["append-only fallback<br/>(logs why)"]
    I --> K["validate_collection():<br/>independent re-count"]
    J --> K
    K --> L{"pass?"}
    L -- yes --> M["upsert_watermark(), status OK"]
    L -- no --> N["status VALIDATION FAILED"]
```

Every collection is auto-discovered from Mongo — nothing is hardcoded —
and every run produces a Rich console report plus two Postgres control
tables (`etl_watermarks`, `etl_logs`) for auditability. Full logic,
including the string-vs-BSON-date watermark gotcha: [`docs/scripts.md`](docs/scripts.md) §1.

---

## 9. Shared infrastructure — `utils/`

Every script in the project (`extract.py`, `sql_test.py`, and anything
added later) builds on three small modules rather than each
reimplementing config-loading, connection handling, and logging:

```mermaid
flowchart TD
    ENVFILE[".env"] -- "load_dotenv()" --> ENGINE["engine.py<br/>reads + validates every env var<br/>ONCE, at import time —<br/>fails loud and early if misconfigured"]
    ENGINE -- "from . import engine" --> CONN["connection.py<br/>get_mongo_db() / get_postgres_engine()<br/>lazy, cached, round-trip-checked"]
    LOGGER["logger.py<br/>get_logger(name)<br/>console + rotating file,<br/>idempotent, no double handlers"] --> CONN
    CONN --> SCRIPTS["scripts/extract.py<br/>scripts/sql_test.py"]
    LOGGER --> SCRIPTS
```

The key design choice: validation happens at **import time**, not
lazily, so a broken `.env` fails immediately with every missing variable
listed at once — instead of surfacing three layers deep inside a
database driver, minutes into a run. Full detail: [`docs/utils.md`](docs/utils.md).

---

## 10. Repository layout

```
walmart
├─ airflow/                 → dags/walmart_pipeline_dag.py, plus bind-mounted logs/plugins/config
├─ docker/                  → Dockerfile, Dockerfile.airflow, docker-compose.yaml, entrypoint.sh, dbt/profiles.yml
├─ docs/                    → this level of documentation (airflow.md, dbt.md, docker.md, pipeline.md, scripts.md, tests.md, utils.md)
├─ jars/                    → Mongo Spark connector + Postgres JDBC jars, checked in for offline Spark startup
├─ pipeline/                → run_pipeline.ps1 (Windows entry point)
├─ scripts/                 → extract.py (Mongo → bronze), sql_test.py (SQL test runner)
├─ sql/                     → hand-written functions/triggers/reports (customer, product, sales-trend analysis)
├─ tests/                   → standalone SQL data-quality suite, one folder per medallion layer
├─ utils/                   → engine.py, connection.py, logger.py — shared infra
├─ walmart_dbt/             → dbt project: silver + gold models, schema tests, custom generics
├─ reports/                 → generated markdown reports + chart PNGs (brand/category analysis)
├─ notebooks/               → exploratory Mongo notebook
├─ main.py                  → entry point for the standalone Docker image
└─ pyproject.toml / uv.lock → dependency management via uv
```

---

## 11. Where to go next

| Question | Doc |
|---|---|
| How does the Airflow DAG work, task by task? | [`docs/airflow.md`](docs/airflow.md) |
| What do the dbt models actually do, layer by layer? | [`docs/dbt.md`](docs/dbt.md) |
| How are the two Docker images built, and what broke getting them running? | [`docs/docker.md`](docs/docker.md) |
| What does the Windows entry-point script do? | [`docs/pipeline.md`](docs/pipeline.md) |
| How does `extract.py` decide incremental vs. full reload? | [`docs/scripts.md`](docs/scripts.md) |
| What do the raw SQL data-quality checks actually check? | [`docs/tests.md`](docs/tests.md) |
| Where does config/connection/logging come from? | [`docs/utils.md`](docs/utils.md) |
