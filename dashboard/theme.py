"""
dashboard/theme.py

One place for chart styling so every Plotly figure in app.py shares the
same fonts, colors, and formatting instead of each chart defaulting to
whatever Plotly picks on its own.
"""

import plotly.graph_objects as go

# Walmart-inspired palette: blue as primary, yellow as accent, plus
# supporting tones for charts with more than two series.
WALMART_BLUE = "#0071CE"
WALMART_YELLOW = "#FFC220"
PALETTE = [
    "#0071CE",  # Walmart blue
    "#FFC220",  # Walmart yellow
    "#004C91",  # deep blue
    "#00A9E0",  # light blue
    "#76B900",  # green
    "#E4002B",  # red
    "#9E2896",  # purple
    "#6E7B8B",  # slate
]

FONT_FAMILY = "'Segoe UI', Helvetica, Arial, sans-serif"


def style(fig: go.Figure, *, currency: bool = True, legend: bool = True, height: int = 380) -> go.Figure:
    """Apply one consistent look to a chart: transparent background (so
    it matches the Streamlit theme), shared font, brand color sequence,
    and optional currency-formatted axis."""
    fig.update_layout(
        font=dict(family=FONT_FAMILY, size=13, color="#1A1A1A"),
        plot_bgcolor="rgba(0,0,0,0)",
        paper_bgcolor="rgba(0,0,0,0)",
        margin=dict(l=10, r=10, t=45, b=10),
        showlegend=legend,
        colorway=PALETTE,
        height=height,
        hoverlabel=dict(font_size=13, font_family=FONT_FAMILY),
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="right", x=1),
    )
    fig.update_xaxes(showgrid=False, showline=True, linecolor="rgba(0,0,0,0.15)")
    fig.update_yaxes(showgrid=True, gridcolor="rgba(0,0,0,0.08)", zeroline=False)
    if currency:
        fig.update_yaxes(tickprefix="$", tickformat=",.0f")
    return fig


def inject_css() -> str:
    """Small CSS polish injected once via st.markdown(unsafe_allow_html=True)."""
    return f"""
    <style>
    div[data-testid="stMetricValue"] {{ font-size: 1.65rem; font-weight: 700; }}
    div[data-testid="stMetricLabel"] {{ font-weight: 600; color: #4a4a4a; }}
    hr {{ border-top: 3px solid {WALMART_YELLOW}; margin-top: 0.5rem; }}
    section[data-testid="stSidebar"] {{ border-right: 1px solid rgba(0,0,0,0.08); }}
    </style>
    """
