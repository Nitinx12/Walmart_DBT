"""
connection.py
==============
Central place for opening/reusing database connections.

Config comes from engine.py (already validated at import time, so if this
module loads without raising, every required env var is present and correct).
Logging goes through utils/logger.py so connection events show up in the
same log files as everything else.

Usage:
    from connection import get_mongo_db, get_postgres_engine

    db = get_mongo_db()
    engine = get_postgres_engine()
"""

import logging

from pymongo import MongoClient
from pymongo.errors import PyMongoError
from sqlalchemy import create_engine
from sqlalchemy.exc import SQLAlchemyError

from . import engine as config
from .logger import get_logger

# console_level=WARNING keeps "Opening MongoDB/Postgres connection..."
# out of the terminal -- those still get written at INFO level to the daily
# log file under logs/, just not echoed to the console on every run.
log = get_logger("connection", console_level=logging.WARNING)

_mongo_client = None
_postgres_engine = None


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
        url = (
            f"postgresql+psycopg2://{config.POSTGRES_USERNAME}:{config.POSTGRES_PASSWORD}"
            f"@{config.POSTGRES_HOST}:{config.POSTGRES_PORT}/{config.POSTGRES_DATABASE}"
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