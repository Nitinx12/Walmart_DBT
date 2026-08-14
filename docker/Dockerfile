# Target location: docker/Dockerfile
#
# Standalone pipeline image. Sibling to docker/Dockerfile.airflow (the
# Airflow CeleryExecutor image) -- same JDK, uv install, and PYTHON*/SPARK*
# env vars, but built on python:3.12-slim instead of the Airflow image, and
# COPY's the project in instead of bind-mounting it, so this image is
# self-contained and can run outside the docker-compose stack:
#
#   docker build -f docker/Dockerfile -t walmart-pipeline .
#   docker run --rm --env-file .env walmart-pipeline
#
# docker/entrypoint.sh runs before CMD: validates the required Postgres env
# vars are set and waits for Postgres to accept connections before handing
# off to CMD via exec "$@".

FROM python:3.12-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-17-jdk-headless \
    curl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV PATH="$JAVA_HOME/bin:$PATH"

RUN pip install --no-cache-dir uv

# Matches Dockerfile.airflow's env vars so behavior is identical whether a
# stage runs via run_pipeline.ps1, this image, or the Airflow one.
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PYTHONPATH=/app
ENV SPARK_EXTRA_CLASSPATH=/app/jars/*
ENV PYSPARK_PYTHON=/app/.venv/bin/python
ENV PYSPARK_DRIVER_PYTHON=/app/.venv/bin/python

WORKDIR /app

# Unlike Dockerfile.airflow (bind-mounted /app), this image needs the
# project baked in -- scripts/, tests/, walmart_dbt/, jars/, pyproject.toml,
# uv.lock -- so it's self-contained and runnable with a plain `docker run`.
COPY . .

RUN uv sync --frozen

# entrypoint.sh comes in via the COPY above as a plain file -- not marked
# executable on disk -- so it needs chmod +x before it can serve as ENTRYPOINT.
RUN chmod +x docker/entrypoint.sh

ENTRYPOINT ["docker/entrypoint.sh"]
CMD ["uv", "run", "main.py"]