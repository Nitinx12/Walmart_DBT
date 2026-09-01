"""
connection.py
==============
Central place for opening/reusing database connections.

Config comes from engine.py (already validated at import time, so if this
module loads without raising, every required env var is present and correct).
Logging goes through utils/logger.py so connection events show up in the
same log files as everything else.

Usage:
    from connection import get_mongo_db, get_postgres_engine, get_databricks_connection

    db = get_mongo_db()
    engine = get_postgres_engine()
    dbx = get_databricks_connection()

Databricks support requires the `databricks-sql-connector` package
(`uv add databricks-sql-connector`).
"""

import logging

from databricks import sql as databricks_sql
from databricks.sql.exc import Error as DatabricksError
from pymongo import MongoClient
from pymongo.errors import PyMongoError
from sqlalchemy import create_engine
from sqlalchemy.engine import URL
from sqlalchemy.exc import SQLAlchemyError

from . import engine as config
from .logger import get_logger

# console_level=WARNING keeps "Opening MongoDB/Postgres connection..."
# out of the terminal -- those still get written at INFO level to the daily
# log file under logs/, just not echoed to the console on every run.
log = get_logger("connection", console_level=logging.WARNING)

_mongo_client = None
_postgres_engine = None
_databricks_connection = None


def get_mongo_db():
    """Return a cached Mongo database handle, creating the client on first use."""
    global _mongo_client

    if _mongo_client is None:
        log.info(f"Opening MongoDB connection to database '{config.MONGO_DB}'")
        try:
            _mongo_client = MongoClient(config.MONGO_URI)
            # Force a round trip now so connection errors surface here,
            # not on the first real query somewhere downstream.
            _mongo_client.admin.command("ping")
        except PyMongoError:
            _mongo_client = None
            log.exception("Failed to connect to MongoDB")
            raise

    return _mongo_client[config.MONGO_DB]


def get_postgres_engine():
    """Return a cached SQLAlchemy engine, creating it on first use."""
    global _postgres_engine

    if _postgres_engine is None:
        log.info(
            f"Opening Postgres connection to "
            f"{config.POSTGRES_HOST}:{config.POSTGRES_PORT}/{config.POSTGRES_DATABASE}"
        )
        # Built with URL.create (not an f-string) so a password containing
        # @, :, or / doesn't corrupt the URL, and so optional sslmode /
        # channel_binding params (needed by managed providers like Neon)
        # can be added without breaking plain local Postgres.
        query = {
            k: v
            for k, v in {
                "sslmode": getattr(config, "POSTGRES_SSLMODE", None),
                "channel_binding": getattr(config, "POSTGRES_CHANNEL_BINDING", None),
            }.items()
            if v
        }
        url = URL.create(
            "postgresql+psycopg2",
            username=config.POSTGRES_USERNAME,
            password=config.POSTGRES_PASSWORD,
            host=config.POSTGRES_HOST,
            port=config.POSTGRES_PORT,
            database=config.POSTGRES_DATABASE,
            query=query,
        )
        try:
            _postgres_engine = create_engine(url)
            # Force a round trip now so connection errors surface here.
            with _postgres_engine.connect():
                pass
        except SQLAlchemyError:
            _postgres_engine = None
            log.exception("Failed to connect to Postgres")
            raise

    return _postgres_engine


def get_databricks_connection():
    """Return a cached Databricks SQL connection, creating it on first use."""
    global _databricks_connection

    if _databricks_connection is None:
        # Unlike Postgres/Mongo, these are only soft-validated in engine.py,
        # so check here and fail loudly the moment a script actually tries
        # to use Databricks without them configured.
        required = {
            "DATABRICKS_HOST": config.DATABRICKS_HOST,
            "DATABRICKS_HTTP_PATH": config.DATABRICKS_HTTP_PATH,
            "DATABRICKS_TOKEN": config.DATABRICKS_TOKEN,
        }
        missing = [name for name, value in required.items() if not value]
        if missing:
            raise OSError(
                f"Missing required environment variables for Databricks: "
                f"{', '.join(missing)}"
            )

        log.info(f"Opening Databricks connection to '{config.DATABRICKS_HOST}'")

        # catalog/schema are optional -- omit them entirely rather than pass
        # None, so the warehouse's own default is used when unset.
        connect_kwargs = {
            "server_hostname": config.DATABRICKS_HOST,
            "http_path": config.DATABRICKS_HTTP_PATH,
            "access_token": config.DATABRICKS_TOKEN,
        }
        if config.DATABRICKS_CATALOG:
            connect_kwargs["catalog"] = config.DATABRICKS_CATALOG
        if config.DATABRICKS_SCHEMA:
            connect_kwargs["schema"] = config.DATABRICKS_SCHEMA

        try:
            _databricks_connection = databricks_sql.connect(**connect_kwargs)
            # Force a round trip now so connection errors surface here,
            # not on the first real query somewhere downstream.
            with _databricks_connection.cursor() as cursor:
                cursor.execute("SELECT 1")
        except DatabricksError:
            _databricks_connection = None
            log.exception("Failed to connect to Databricks")
            raise

    return _databricks_connection
