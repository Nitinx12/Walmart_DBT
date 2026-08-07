"""
utils/logger.py
================
Central logging setup, shared by any script in this project.

- Logs to console AND to a rotating file under logs/.
- One log file per day (e.g. logs/incremental_load_2026-07-28.log),
  auto-rotated by size too, so old runs are never lost.
- Console and file can each have their own verbosity. By default both show
  everything at `level` (unchanged from before), but a script can pass
  `console_level` to keep the terminal quiet (e.g. only warnings/errors)
  while the file still captures full detail for later debugging.

Usage:
    from utils.logger import get_logger
    log = get_logger("incremental_loader")

    # Quiet terminal, full detail in the log file:
    log = get_logger("incremental_loader", console_level=logging.WARNING)
"""

import logging
import os
from datetime import datetime
from logging.handlers import RotatingFileHandler

LOG_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "logs"
)
LOG_FORMAT = "%(asctime)s | %(levelname)-8s | %(name)s | %(message)s"
DATE_FORMAT = "%Y-%m-%d %H:%M:%S"


def get_logger(
    name: str = "app", level: int = logging.INFO, console_level: int | None = None
) -> logging.Logger:
    os.makedirs(LOG_DIR, exist_ok=True)

    logger = logging.getLogger(name)

    # Avoid attaching duplicate handlers if get_logger() is called more than once
    if logger.handlers:
        return logger

    # The logger itself stays permissive; each handler filters independently
    # so console and file can show different levels of detail.
    logger.setLevel(logging.DEBUG)
    formatter = logging.Formatter(LOG_FORMAT, datefmt=DATE_FORMAT)

    # Console handler
    console_handler = logging.StreamHandler()
    console_handler.setLevel(console_level if console_level is not None else level)
    console_handler.setFormatter(formatter)
    logger.addHandler(console_handler)

    # File handler: one file per day, rotated further if it grows past 5MB.
    # Uses local time (via astimezone) so the file rolls over on the local
    # calendar day, same as before, while still satisfying DTZ005.
    log_filename = f"{name}_{datetime.now().astimezone().strftime('%Y-%m-%d')}.log"
    file_handler = RotatingFileHandler(
        os.path.join(LOG_DIR, log_filename),
        maxBytes=5 * 1024 * 1024,  # 5 MB
        backupCount=5,
        encoding="utf-8",
    )
    file_handler.setLevel(level)
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)

    logger.propagate = False
    return logger