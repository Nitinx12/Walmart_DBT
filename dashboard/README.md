# Sales Dashboard

Interactive Streamlit + Plotly dashboard reading directly from the
`gold` star schema built by `walmart_dbt`.

## Run it

```powershell
uv add streamlit plotly
uv run streamlit run dashboard/app.py
```

Requires the same `.env` as the rest of the project (`POSTGRES_HOST`,
`POSTGRES_PORT`, `POSTGRES_DATABASE`, `POSTGRES_USERNAME`,
`POSTGRES_PASSWORD`, `POSTGRES_SCHEMA_GOLD`) — it reuses
`utils/engine.py` and `utils/connection.py`, the same config/connection
layer `extract.py` and `sql_test.py` use, so nothing new to configure.

## Layout

| File | Responsibility |
|---|---|
| `app.py` | Streamlit UI: sidebar filters, KPI cards, chart layout |
| `queries.py` | All SQL — parameterized, aggregated in Postgres, no business logic in `app.py` |
| `theme.py` | Shared Plotly styling (Walmart-branded palette, fonts, formatting) |
| `../.streamlit/config.toml` | Streamlit chrome theme, matching the chart palette |

## Design choices worth knowing

- **Aggregation happens in SQL, not pandas.** Every chart's query does
  its own `GROUP BY` in Postgres and returns only the summarized rows —
  the app never pulls the full `fact_order_items` table into memory.
  This is what lets it stay fast as the fact table grows.
- **`is_active = true` is enforced on every query** (`fact_order_items`
  and `dim_orders`), matching the soft-delete convention used elsewhere
  in the gold layer.
- **KPI cards show period-over-period deltas** — the current filter
  window compared against an equal-length prior window — not just raw
  totals.
- **`Filters` is a frozen dataclass**, not a dict, so Streamlit's
  `@st.cache_data` can hash it directly as a cache key across reruns.
- The "recent order lines" expander pulls a bounded sample (200 rows),
  not the full filtered set, for the same reason.

## Extending it

- A proper `dim_date` table (fiscal periods, holiday flags) would make
  `get_revenue_trend`'s granularity toggle richer than plain
  `date_trunc`.
- `get_revenue_by()` in `queries.py` is a small whitelist-driven helper —
  adding a new breakdown chart (e.g. by customer province) is a one-line
  addition to `_DIMENSION_COLUMNS`, not a new query function.
