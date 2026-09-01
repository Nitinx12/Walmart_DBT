import os
import warnings

from dotenv import load_dotenv

if not load_dotenv():
    print("Warning: no .env file found, relying on system environment variables")

# =========================================================
# POSTGRES
# =========================================================
POSTGRES_HOST = os.getenv("POSTGRES_HOST")
POSTGRES_PORT = os.getenv("POSTGRES_PORT")
POSTGRES_DATABASE = os.getenv("POSTGRES_DATABASE")
POSTGRES_USERNAME = os.getenv("POSTGRES_USERNAME")
POSTGRES_PASSWORD = os.getenv("POSTGRES_PASSWORD")
# Optional: required by managed providers like Neon, unset/None for plain
# local Postgres so this never breaks the Docker dev setup.
POSTGRES_SSLMODE = os.getenv("POSTGRES_SSLMODE")
POSTGRES_CHANNEL_BINDING = os.getenv("POSTGRES_CHANNEL_BINDING")

# Cast port to int now, fail loudly later if it's garbage instead of silently
# passing a string into a driver that expects int.
if POSTGRES_PORT is not None:
    try:
        POSTGRES_PORT = int(POSTGRES_PORT)
    except ValueError:
        raise OSError(f"POSTGRES_PORT must be an integer, got: {POSTGRES_PORT!r}")

# Postgres schemas (medallion architecture). Optional: only needed by
# scripts that actually build a bronze/silver/gold layout. mongo_exp.py
# writes straight into the `public` schema and does not touch these.
POSTGRES_SCHEMA_BRONZE = os.getenv("POSTGRES_SCHEMA_BRONZE")
POSTGRES_SCHEMA_SILVER = os.getenv("POSTGRES_SCHEMA_SILVER")
POSTGRES_SCHEMA_GOLD = os.getenv("POSTGRES_SCHEMA_GOLD")

# =========================================================
# PYSPARK
# =========================================================
# Read here mainly so a missing value fails fast with a clear message;
# Spark itself picks these up from the process environment once load_dotenv()
# has run, so this doesn't need to be passed anywhere manually.
PYSPARK_PYTHON = os.getenv("PYSPARK_PYTHON")
PYSPARK_DRIVER_PYTHON = os.getenv("PYSPARK_DRIVER_PYTHON")

# =========================================================
# MONGODB
# =========================================================
MONGO_URI = os.getenv("MONGO_URI")
MONGO_DB = os.getenv("MONGO_DB")

# =========================================================
# DATABRICKS
# =========================================================
DATABRICKS_HOST = os.getenv("DATABRICKS_HOST")
DATABRICKS_HTTP_PATH = os.getenv("DATABRICKS_HTTP_PATH")
DATABRICKS_TOKEN = os.getenv("DATABRICKS_TOKEN")
# Optional: scopes queries to a specific catalog/schema instead of the SQL
# warehouse's default. Only needed by scripts that actually target Databricks.
DATABRICKS_CATALOG = os.getenv("DATABRICKS_CATALOG")
DATABRICKS_SCHEMA = os.getenv("DATABRICKS_SCHEMA")


# =========================================================
# VALIDATION
# =========================================================
# Hard-required: every script in this project touches Postgres and/or
# Mongo, so these must always be present or nothing can run.
_required = {
    "POSTGRES_HOST": POSTGRES_HOST,
    "POSTGRES_PORT": POSTGRES_PORT,
    "POSTGRES_DATABASE": POSTGRES_DATABASE,
    "POSTGRES_USERNAME": POSTGRES_USERNAME,
    "POSTGRES_PASSWORD": POSTGRES_PASSWORD,
    "MONGO_URI": MONGO_URI,
    "MONGO_DB": MONGO_DB,
}

_missing = [k for k, v in _required.items() if not v]

if _missing:
    raise OSError(f"Missing required environment variables: {', '.join(_missing)}")

# Soft-required: only needed by scripts that build a bronze/silver/gold
# schema layout. Missing values here don't stop the Mongo -> Postgres
# pipeline from running, but scripts that DO use them will fail with a
# clear error the moment they're actually touched -- not silently.
_optional = {
    "POSTGRES_SCHEMA_BRONZE": POSTGRES_SCHEMA_BRONZE,
    "POSTGRES_SCHEMA_SILVER": POSTGRES_SCHEMA_SILVER,
    "POSTGRES_SCHEMA_GOLD": POSTGRES_SCHEMA_GOLD,
}

_missing_optional = [k for k, v in _optional.items() if not v]

if _missing_optional:
    warnings.warn(
        "Not set (only needed if you use the bronze/silver/gold schemas): "
        f"{', '.join(_missing_optional)}",
        stacklevel=2,
    )

# Soft-required: only needed by scripts that actually connect to Databricks.
# Missing values here don't stop the Postgres/Mongo pipeline from running,
# but get_databricks_connection() in connection.py will fail with a clear
# error the moment it's actually called without them.
_optional_databricks = {
    "DATABRICKS_HOST": DATABRICKS_HOST,
    "DATABRICKS_HTTP_PATH": DATABRICKS_HTTP_PATH,
    "DATABRICKS_TOKEN": DATABRICKS_TOKEN,
    "DATABRICKS_CATALOG": DATABRICKS_CATALOG,
    "DATABRICKS_SCHEMA": DATABRICKS_SCHEMA,
}

_missing_databricks = [k for k, v in _optional_databricks.items() if not v]

if _missing_databricks:
    warnings.warn(
        "Not set (only needed if you connect to Databricks): "
        f"{', '.join(_missing_databricks)}",
        stacklevel=2,
    )