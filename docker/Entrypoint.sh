#!/usr/bin/env bash
set -euo pipefail

# Target location: docker/entrypoint.sh
#
# Runs before CMD on every start of the docker/Dockerfile image. Not used by
# Dockerfile.airflow -- that image keeps the official Airflow entrypoint.
#
#   1. Fails fast with a clear message if a required Postgres env var is
#      missing, instead of a stack trace three layers deep in main.py.
#   2. Waits for Postgres to actually accept connections -- useful since
#      container start order alone doesn't guarantee the DB is ready to
#      accept connections yet, whether run via `docker run` or compose.
#   3. execs the image's CMD (or whatever command was passed), so
#      `docker run <image> bash` / pytest / etc. still work normally.
#
# Scoped to the Postgres vars ps1's own header comment lists as required
# (POSTGRES_HOST/PORT/DATABASE/USERNAME/PASSWORD). Mongo isn't checked here
# since it wasn't in that list -- extract.py will surface a Mongo connection
# failure directly if that's ever the problem instead.

REQUIRED_VARS=(POSTGRES_HOST POSTGRES_PORT POSTGRES_DATABASE POSTGRES_USERNAME POSTGRES_PASSWORD)
missing=()
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var:-}" ]; then
    missing+=("$var")
  fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "ERROR: missing required environment variable(s): ${missing[*]}" >&2
  echo "Set them via docker-compose environment/env_file, or -e on docker run." >&2
  exit 1
fi

echo "Waiting for Postgres at ${POSTGRES_HOST}:${POSTGRES_PORT}..."
attempt=0
max_attempts=30
until (exec 3<>"/dev/tcp/${POSTGRES_HOST}/${POSTGRES_PORT}") 2>/dev/null; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "ERROR: Postgres not reachable at ${POSTGRES_HOST}:${POSTGRES_PORT} after ${max_attempts} attempts (60s)." >&2
    exit 1
  fi
  sleep 2
done
exec 3<&- 3>&- 2>/dev/null || true
echo "Postgres is reachable."

exec "$@"