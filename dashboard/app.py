"""
Walmart Sales Dashboard — Streamlit + Plotly, backed by the Postgres
`gold` star schema.

Run from the repo root:
    uv add streamlit plotly
    uv run streamlit run dashboard/app.py

Design notes:
- All SQL lives in queries.py, parameterized and aggregated in Postgres —
  this file only shapes UI state and renders results.
- Chart styling lives in theme.py so every figure looks consistent.
- Filters is a frozen dataclass so Streamlit's cache can key on it.
"""

import sys
from datetime import timedelta
from pathlib import Path

# dashboard/app.py -> repo root is one level up. Put it on sys.path so
# `from utils....` resolves no matter what directory Streamlit is
# launched from.
PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

import plotly.express as px
import streamlit as st

from dashboard.queries import (
    Filters,
    get_category_brand_treemap,
    get_filter_options,
    get_kpis,
    get_recent_order_lines,
    get_revenue_by,
    get_revenue_trend,
    get_top_customers,
    get_top_products,
)
from dashboard.theme import PALETTE, inject_css, style
from utils.logger import get_logger

log = get_logger("dashboard", console_level="WARNING")

st.set_page_config(page_title="Walmart Sales Dashboard", page_icon="🛒", layout="wide")
st.markdown(inject_css(), unsafe_allow_html=True)


# ---------------------------------------------------------------------------
# Load filter options (small query, cached an hour) before rendering the
# sidebar, so widgets have real bounds instead of arbitrary defaults.
# ---------------------------------------------------------------------------
try:
    options = get_filter_options()
except Exception as exc:  # noqa: BLE001 — surface connection/config errors plainly
    log.exception("Failed to load filter options from gold schema")
    st.error(f"Could not connect to the database: {exc}")
    st.stop()

if not options["stores"]:
    st.warning("No active stores found in the gold schema yet. Has the pipeline run?")
    st.stop()


# ---------------------------------------------------------------------------
# Sidebar filters
# ---------------------------------------------------------------------------
st.sidebar.header("Filters")

selected_range = st.sidebar.date_input(
    "Order date range",
    value=(options["min_date"], options["max_date"]),
    min_value=options["min_date"],
    max_value=options["max_date"],
)
if isinstance(selected_range, tuple) and len(selected_range) == 2:
    start_date, end_date_inclusive = selected_range
else:
    start_date, end_date_inclusive = options["min_date"], options["max_date"]

selected_stores = st.sidebar.multiselect("Store(s)", options["stores"], default=options["stores"])
selected_categories = st.sidebar.multiselect("Categor(y/ies)", options["categories"], default=options["categories"])
selected_statuses = st.sidebar.multiselect("Order status", options["statuses"], default=options["statuses"])

granularity_label = st.sidebar.radio("Trend granularity", ["Day", "Week", "Month"], index=1, horizontal=True)
granularity = granularity_label.lower()

filters = Filters(
    start_date=start_date,
    end_date=end_date_inclusive + timedelta(days=1),  # inclusive UI date -> exclusive SQL bound
    stores=tuple(selected_stores),
    categories=tuple(selected_categories),
    statuses=tuple(selected_statuses),
)


# ---------------------------------------------------------------------------
# KPIs, with period-over-period deltas
# ---------------------------------------------------------------------------
st.title("🛒 Walmart Sales Dashboard")
st.caption(f"{start_date:%b %d, %Y} – {end_date_inclusive:%b %d, %Y} · gold schema, live from Postgres")

current = get_kpis(filters)
previous = get_kpis(filters.previous_period())


def _delta(curr: float, prev: float) -> str | None:
    if not prev:
        return None
    pct = (curr - prev) / prev * 100
    return f"{pct:+.1f}% vs prior period"


if current["orders"] == 0:
    st.info("No order lines match the current filters.")
    st.stop()

col1, col2, col3, col4 = st.columns(4)
col1.metric("Total Revenue", f"${current['revenue']:,.0f}", _delta(current["revenue"], previous["revenue"]))
col2.metric("Orders", f"{current['orders']:,}", _delta(current["orders"], previous["orders"]))
col3.metric("Customers", f"{current['customers']:,}", _delta(current["customers"], previous["customers"]))
col4.metric("Avg Order Value", f"${current['aov']:,.2f}", _delta(current["aov"], previous["aov"]))

st.divider()


# ---------------------------------------------------------------------------
# Revenue trend
# ---------------------------------------------------------------------------
st.subheader("Revenue Trend")
trend = get_revenue_trend(filters, granularity)
fig_trend = px.area(
    trend, x="period", y="revenue",
    labels={"period": "", "revenue": "Revenue"},
)
fig_trend.update_traces(line=dict(color=PALETTE[0], width=2.5), fillcolor="rgba(0,113,206,0.15)")
st.plotly_chart(style(fig_trend, legend=False, height=340), use_container_width=True)


# ---------------------------------------------------------------------------
# Store / Category breakdown
# ---------------------------------------------------------------------------
left, right = st.columns(2)

with left:
    st.subheader("Revenue by Store")
    by_store = get_revenue_by(filters, "store")
    fig_store = px.bar(
        by_store, x="store", y="revenue", color="revenue",
        color_continuous_scale=["#B3D9F2", PALETTE[0]],
        labels={"store": "", "revenue": "Revenue"},
    )
    fig_store.update_layout(coloraxis_showscale=False)
    st.plotly_chart(style(fig_store, legend=False), use_container_width=True)

with right:
    st.subheader("Revenue by Category")
    by_category = get_revenue_by(filters, "category")
    fig_category = px.pie(by_category, names="category", values="revenue", hole=0.55)
    fig_category.update_traces(textposition="outside", textinfo="percent+label")
    st.plotly_chart(style(fig_category, currency=False, legend=False), use_container_width=True)


# ---------------------------------------------------------------------------
# Brand / Payment method breakdown
# ---------------------------------------------------------------------------
left2, right2 = st.columns(2)

with left2:
    st.subheader("Top 10 Brands by Revenue")
    by_brand = get_revenue_by(filters, "brand", limit=10)
    fig_brand = px.bar(
        by_brand, x="revenue", y="brand", orientation="h",
        labels={"brand": "", "revenue": "Revenue"},
    )
    fig_brand.update_layout(yaxis={"categoryorder": "total ascending"})
    st.plotly_chart(style(fig_brand, legend=False), use_container_width=True)

with right2:
    st.subheader("Revenue by Payment Method")
    by_payment = get_revenue_by(filters, "payment_method")
    fig_payment = px.pie(by_payment, names="payment_method", values="revenue", hole=0.55)
    fig_payment.update_traces(textposition="outside", textinfo="percent+label")
    st.plotly_chart(style(fig_payment, currency=False, legend=False), use_container_width=True)


# ---------------------------------------------------------------------------
# Category -> Brand treemap
# ---------------------------------------------------------------------------
st.subheader("Category → Brand Revenue Breakdown")
treemap_data = get_category_brand_treemap(filters)
if not treemap_data.empty:
    fig_tree = px.treemap(
        treemap_data, path=["category_name", "brand_name"], values="revenue",
        color="revenue", color_continuous_scale=["#B3D9F2", PALETTE[2]],
    )
    fig_tree.update_traces(textinfo="label+value")
    fig_tree.update_layout(coloraxis_showscale=False)
    st.plotly_chart(style(fig_tree, currency=False, legend=False, height=420), use_container_width=True)
else:
    st.caption("No category/brand data for the current filters.")

st.divider()


# ---------------------------------------------------------------------------
# Tables
# ---------------------------------------------------------------------------
tbl_left, tbl_right = st.columns(2)

with tbl_left:
    st.subheader("Top 10 Products")
    st.dataframe(
        get_top_products(filters, limit=10),
        use_container_width=True, hide_index=True,
        column_config={
            "revenue": st.column_config.NumberColumn("Revenue", format="$%.0f"),
            "units_sold": st.column_config.NumberColumn("Units Sold"),
        },
    )

with tbl_right:
    st.subheader("Top 10 Customers")
    st.dataframe(
        get_top_customers(filters, limit=10),
        use_container_width=True, hide_index=True,
        column_config={"revenue": st.column_config.NumberColumn("Revenue", format="$%.0f")},
    )

with st.expander("Recent order lines matching filters (most recent 200)"):
    st.dataframe(get_recent_order_lines(filters, limit=200), use_container_width=True, hide_index=True)