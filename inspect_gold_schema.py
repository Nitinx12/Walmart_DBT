"""
Quick one-off: list every table + column in the Postgres `gold` schema,
using this project's own utils/connection.py so it respects .env exactly
the way extract.py and everything else does.

Run from the repo root:
    uv run python inspect_gold_schema.py
"""

import pandas as pd

from utils.connection import get_postgres_engine

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
