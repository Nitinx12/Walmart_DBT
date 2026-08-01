from dotenv import load_dotenv
import os
import warnings

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

# Cast port to int now, fail loudly later if it's garbage instead of silently
# passing a string into a driver that expects int.
if POSTGRES_PORT is not None:
    try:
        POSTGRES_PORT = int(POSTGRES_PORT)
    except ValueError:
        raise EnvironmentError(
            f"POSTGRES_PORT must be an integer, got: {POSTGRES_PORT!r}"
        )

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
    raise EnvironmentError(
        f"Missing required environment variables: {', '.join(_missing)}"
    )

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