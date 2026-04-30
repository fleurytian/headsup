"""Internal analytics dashboard.

Gated by `ADMIN_TOKEN` env. Read-only — only counts and aggregates.
Designed to be cheap on the live DB; runs a handful of small SELECT COUNT
queries with date-range filters. No background jobs, no caching.

URL: GET /admin?token=<ADMIN_TOKEN>
"""
from __future__ import annotations
from datetime import datetime, timedelta
from collections import OrderedDict
from typing import Optional

from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import HTMLResponse
from sqlmodel import Session, func, select

from config import settings
from database import engine
from models import (
    Agent,
    AgentUserBinding,
    AppUser,
    Event,
    PushMessage,
    WebhookDelivery,
)

router = APIRouter(tags=["admin"], include_in_schema=False)


def _require_admin(token: str) -> None:
    if not settings.admin_token:
        raise HTTPException(401, "Admin dashboard disabled (no ADMIN_TOKEN configured)")
    if token != settings.admin_token:
        raise HTTPException(401, "Bad admin token")


def _count(session: Session, model, *filters) -> int:
    q = select(func.count(model.id)).where(*filters) if filters else select(func.count(model.id))
    val = session.exec(q).one()
    if isinstance(val, tuple):
        val = val[0] if val else 0
    return int(val or 0)


def _distinct_actors_per_day(session: Session, kind: str, days: int) -> "OrderedDict[str, int]":
    """For each of the last `days` UTC days, count distinct actor_id on events of `kind`."""
    out: "OrderedDict[str, int]" = OrderedDict()
    today = datetime.utcnow().replace(hour=0, minute=0, second=0, microsecond=0)
    for i in range(days - 1, -1, -1):
        start = today - timedelta(days=i)
        end = start + timedelta(days=1)
        rows = session.exec(
            select(Event.actor_id).where(
                Event.kind == kind,
                Event.created_at >= start,
                Event.created_at < end,
            ).distinct()
        ).all()
        out[start.strftime("%m-%d")] = sum(1 for r in rows if r)
    return out


def _events_per_day(session: Session, kind: str, days: int) -> "OrderedDict[str, int]":
    out: "OrderedDict[str, int]" = OrderedDict()
    today = datetime.utcnow().replace(hour=0, minute=0, second=0, microsecond=0)
    for i in range(days - 1, -1, -1):
        start = today - timedelta(days=i)
        end = start + timedelta(days=1)
        out[start.strftime("%m-%d")] = _count(
            session, Event,
            Event.kind == kind,
            Event.created_at >= start,
            Event.created_at < end,
        )
    return out


def _spark(values: list[int], width: int = 28) -> str:
    """Tiny unicode-block sparkline (no js)."""
    if not values:
        return ""
    blocks = "▁▂▃▄▅▆▇█"
    lo, hi = min(values), max(values)
    span = max(1, hi - lo)
    return "".join(blocks[min(7, int((v - lo) / span * 7))] for v in values)


@router.get("/admin", response_class=HTMLResponse)
def admin_dashboard(token: str = Query(default="")):
    _require_admin(token)
    with Session(engine) as session:
        # Totals
        agents_total   = _count(session, Agent)
        users_total    = _count(session, AppUser)
        bindings_total = _count(session, AgentUserBinding, AgentUserBinding.status == "active")
        pushes_total   = _count(session, PushMessage)
        replies_total  = _count(session, WebhookDelivery)

        # 24h windows
        last_24h = datetime.utcnow() - timedelta(hours=24)
        last_7d  = datetime.utcnow() - timedelta(days=7)
        pushes_24h = _count(session, PushMessage, PushMessage.created_at >= last_24h)
        pushes_7d  = _count(session, PushMessage, PushMessage.created_at >= last_7d)
        replies_24h = _count(session, WebhookDelivery, WebhookDelivery.created_at >= last_24h)

        dau = _distinct_actors_per_day(session, "app_opened", 7)
        push_per_day  = _events_per_day(session, "push_sent", 14)
        reply_per_day = _events_per_day(session, "push_replied", 14)
        auth_per_day  = _events_per_day(session, "agent_authorized", 14)

        reply_rate = (replies_total / pushes_total * 100.0) if pushes_total else 0.0

    rows = []
    rows.append(("Total agents",      agents_total,    None))
    rows.append(("Total users",       users_total,     None))
    rows.append(("Active bindings",   bindings_total,  None))
    rows.append(("Total pushes",      pushes_total,    f"24h: {pushes_24h} · 7d: {pushes_7d}"))
    rows.append(("Total replies",     replies_total,   f"24h: {replies_24h}"))
    rows.append(("Reply rate",        f"{reply_rate:.1f}%", None))

    def _series_html(label: str, series: "OrderedDict[str, int]") -> str:
        values = list(series.values())
        labels = list(series.keys())
        spark = _spark(values)
        peak = max(values) if values else 0
        recent = values[-1] if values else 0
        return (
            f"<div class='spark'>"
            f"<div class='spark-row'><span class='spark-label'>{label}</span>"
            f"<span class='spark-recent'>today {recent}</span></div>"
            f"<div class='spark-line'>{spark}</div>"
            f"<div class='spark-axis'>{labels[0]} … {labels[-1]} · peak {peak}</div>"
            f"</div>"
        )

    rows_html = "".join(
        f"<tr><td>{name}</td><td class='num'>{val}</td><td class='aux'>{aux or ''}</td></tr>"
        for name, val, aux in rows
    )

    sparks_html = "".join([
        _series_html("DAU (app opens)", dau),
        _series_html("Pushes / day",    push_per_day),
        _series_html("Replies / day",   reply_per_day),
        _series_html("New bindings/d",  auth_per_day),
    ])

    return f"""<!doctype html>
<html><head><meta charset='utf-8'><title>HeadsUp · Admin</title>
<style>
  body {{ font-family: -apple-system, system-ui, sans-serif;
         max-width: 720px; margin: 40px auto; padding: 0 24px;
         color: #1A1818; background: #FFFDF8; }}
  h1 {{ font-size: 22px; margin: 0 0 4px; letter-spacing: -0.2px; }}
  .meta {{ color: #8B8580; font-size: 12px; margin-bottom: 28px;
          font-family: ui-monospace, "SF Mono", Menlo, monospace; }}
  table {{ width: 100%; border-collapse: collapse; margin-bottom: 28px; }}
  th, td {{ text-align: left; padding: 10px 8px; border-bottom: 1px solid #E8E2D5; }}
  td.num {{ font-weight: 600; font-variant-numeric: tabular-nums; }}
  td.aux {{ color: #8B8580; font-size: 12px;
           font-family: ui-monospace, "SF Mono", Menlo, monospace; }}
  .spark {{ padding: 14px 0; border-bottom: 1px solid #E8E2D5; }}
  .spark-row {{ display: flex; justify-content: space-between;
                font-size: 12px; color: #6B60A8; font-weight: 600;
                font-family: ui-monospace, "SF Mono", Menlo, monospace;
                letter-spacing: 0.5px; text-transform: uppercase; }}
  .spark-recent {{ color: #8B8580; }}
  .spark-line {{ font-size: 24px; font-family: ui-monospace, "SF Mono", monospace;
                 letter-spacing: 1px; line-height: 1; padding: 8px 0; color: #1A1818; }}
  .spark-axis {{ font-size: 11px; color: #8B8580;
                 font-family: ui-monospace, "SF Mono", Menlo, monospace; }}
  .footer {{ color: #8B8580; font-size: 12px; margin-top: 36px;
             padding-top: 16px; border-top: 1px solid #E8E2D5; }}
</style></head>
<body>
  <h1>HeadsUp · Admin</h1>
  <div class='meta'>generated {datetime.utcnow().strftime('%Y-%m-%d %H:%M UTC')}</div>
  <table>{rows_html}</table>
  {sparks_html}
  <div class='footer'>Read-only. Refresh the page for fresh numbers.</div>
</body></html>"""
