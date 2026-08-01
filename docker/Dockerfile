FROM python:3.12-slim

# Prevent Python from writing .pyc files
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Install Java (required for Spark) + build tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-17-jdk-headless \
    curl \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Java environment
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV PATH="$JAVA_HOME/bin:$PATH"

# Install uv
RUN pip install --no-cache-dir uv

WORKDIR /app

# Copy dependency files first (better Docker cache)
COPY pyproject.toml uv.lock ./

# Install Python dependencies
RUN uv sync --frozen --no-dev

# Copy project
COPY . .

# Python path
ENV PYTHONPATH=/app

# Spark jars
ENV SPARK_EXTRA_CLASSPATH=/app/jars/*

# PySpark should use the venv uv just created (Linux path, not Windows)
ENV PYSPARK_PYTHON=/app/.venv/bin/python
ENV PYSPARK_DRIVER_PYTHON=/app/.venv/bin/python

# Run as non-root
RUN useradd --create-home appuser && chown -R appuser:appuser /app
USER appuser

CMD ["uv", "run", "python", "main.py"]