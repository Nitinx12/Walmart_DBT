"""
Quick one-off: list every table + column in the Postgres `gold` schema,
using this project's own utils/connection.py so it respects .env exactly
the way extract.py and everything else does.

Lives in scripts/, so the repo root is added to sys.path below — that's
what makes `from utils.connection import ...` resolve regardless of your
current directory.

Run from the repo root:
    uv run python scripts/inspect_gold_schema.py
or from inside scripts/:
    uv run python inspect_gold_schema.py
"""

import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from utils.connection import get_postgres_engine  # noqa: E402

engine = get_postgres_engine()

query = """
    SELECT table_name, column_name, data_type
    FROM information_schema.columns
    WHERE table_schema = 'gold'
    ORDER BY table_name, ordinal_position
"""

df = pd.read_sql(query, engine)

if df.empty:
    print("No tables found in the 'gold' schema. Check POSTGRES_SCHEMA_GOLD in .env "
          "and that dbt has actually built the gold models yet.")
else:
    for table_name, group in df.groupby("table_name"):
        print(f"\n{table_name}")
        print("-" * len(table_name))
        for _, row in group.iterrows():
            print(f"  {row['column_name']:<30} {row['data_type']}")
