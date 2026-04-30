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


def _sla_window(session: Session, since: datetime) -> dict:
    """Return delivery + reply rates over the window starting at `since`.

    Cheap: 4 SELECT COUNTs against indexed columns. No joins. Honest about
    the denominators — we only count things that *should* have a delivery
    outcome, so info_only and suppressed (mark-as-read) rows are excluded.
    """
    pushes = _count(
        session, PushMessage,
        PushMessage.created_at >= since,
    )
    pushes_delivered = _count(
        session, PushMessage,
        PushMessage.created_at >= since,
        PushMessage.status == "delivered",
    )
    pushes_failed = _count(
        session, PushMessage,
        PushMessage.created_at >= since,
        PushMessage.status == "failed",
    )
    # Webhook deliveries: ignore "_read" suppressed receipts — they're an
    # internal mark-as-read trick, not a real reply event.
    webhooks = _count(
        session, WebhookDelivery,
        WebhookDelivery.created_at >= since,
        WebhookDelivery.status != "suppressed",
    )
    webhooks_delivered = _count(
        session, WebhookDelivery,
        WebhookDelivery.created_at >= since,
        WebhookDelivery.status == "delivered",
    )
    webhooks_failed = _count(
        session, WebhookDelivery,
        WebhookDelivery.created_at >= since,
        WebhookDelivery.status == "failed",
    )
    return {
        "pushes":              pushes,
        "pushes_delivered":    pushes_delivered,
        "pushes_failed":       pushes_failed,
        "webhooks":            webhooks,
        "webhooks_delivered":  webhooks_delivered,
        "webhooks_failed":     webhooks_failed,
        "push_delivery_rate":  (pushes_delivered / pushes * 100.0) if pushes else None,
        "webhook_delivery_rate": (webhooks_delivered / webhooks * 100.0) if webhooks else None,
        "reply_rate":          (webhooks / pushes * 100.0) if pushes else None,
    }


def _avg_webhook_attempts(session: Session, since: datetime) -> Optional[float]:
    """Mean number of attempts the webhook worker needed to deliver successfully.
    Higher → more flaky agent endpoints. None if no successes in window."""
    avg = session.exec(
        select(func.avg(WebhookDelivery.attempts)).where(
            WebhookDelivery.created_at >= since,
            WebhookDelivery.status == "delivered",
            WebhookDelivery.attempts > 0,
        )
    ).one()
    if isinstance(avg, tuple):
        avg = avg[0] if avg else None
    return float(avg) if avg is not None else None


def _webhook_pending_backlog(session: Session) -> int:
    """How many webhook deliveries are waiting on retry right now.
    Healthy: 0-2. Persistent non-zero → an agent's endpoint is unreachable."""
    return _count(session, WebhookDelivery, WebhookDelivery.status == "pending")


def _auth_funnel(session: Session, since: datetime) -> dict:
    """Auth-link conversion: created → used → expired-without-use.

    Source of truth is `AuthorizationRequest` (the canonical record), not
    Event log — survives event-table truncation. Counts links *created*
    in the window; whether they're used can happen later within the
    30-min TTL.
    """
    from models import AuthorizationRequest
    created = _count(
        session, AuthorizationRequest,
        AuthorizationRequest.created_at >= since,
    )
    used = _count(
        session, AuthorizationRequest,
        AuthorizationRequest.created_at >= since,
        AuthorizationRequest.used == True,
    )
    expired_unused = _count(
        session, AuthorizationRequest,
        AuthorizationRequest.created_at >= since,
        AuthorizationRequest.used == False,
        AuthorizationRequest.expires_at < datetime.utcnow(),
    )
    return {
        "created":         created,
        "used":            used,
        "expired_unused":  expired_unused,
        "conversion_rate": (used / created * 100.0) if created else None,
    }


def _binding_lifecycle(session: Session, since: datetime) -> dict:
    """New + revoked counts for the window."""
    new_bindings = _count(
        session, AgentUserBinding,
        AgentUserBinding.bound_at >= since,
    )
    # We don't track revoked-at; use Event log instead for the time window.
    revoked = _count(
        session, Event,
        Event.kind == "agent_revoked",
        Event.created_at >= since,
    )
    return {
        "new":     new_bindings,
        "revoked": revoked,
        "net":     new_bindings - revoked,
    }


def _engagement_window(session: Session, since: datetime) -> dict:
    """User engagement signals over the window."""
    bulk_marked_read = _count(
        session, Event,
        Event.kind == "bulk_marked_read",
        Event.created_at >= since,
    )
    # No dedicated event for bulk-defer right now; count agent_revoked is
    # not the same thing. Skip until we add it.
    deletes_canceled = _count(
        session, Event,
        Event.kind == "delete_account_canceled",
        Event.created_at >= since,
    )
    distinct_active = session.exec(
        select(Event.actor_id).where(
            Event.kind == "app_opened",
            Event.actor_kind == "user",
            Event.created_at >= since,
            Event.actor_id != None,
        ).distinct()
    ).all()
    active_users = sum(1 for r in distinct_active if r)
    return {
        "active_users":       active_users,
        "bulk_marked_read":   bulk_marked_read,
        "deletes_canceled":   deletes_canceled,
    }


def _rejections_window(session: Session, since: datetime) -> dict:
    """How often /v1/push got rejected, broken out by reason."""
    quota = _count(
        session, Event,
        Event.kind == "push_rejected_quota",
        Event.created_at >= since,
    )
    user_muted = _count(
        session, Event,
        Event.kind == "push_rejected_user_muted",
        Event.created_at >= since,
    )
    agent_muted = _count(
        session, Event,
        Event.kind == "push_rejected_agent_muted",
        Event.created_at >= since,
    )
    return {
        "quota_exceeded":  quota,
        "user_muted":      user_muted,
        "agent_muted":     agent_muted,
    }


@router.get("/admin", response_class=HTMLResponse)
def admin_dashboard(token: str = Query(default="")):
    _require_admin(token)
    with Session(engine) as session:
        # Totals
        agents_total   = _count(session, Agent)
        users_total    = _count(session, AppUser)
        bindings_total = _count(session, AgentUserBinding, AgentUserBinding.status == "active")
        pushes_total   = _count(session, PushMessage)
        replies_total  = _count(session, WebhookDelivery, WebhookDelivery.status != "suppressed")

        # SLA windows
        now      = datetime.utcnow()
        last_24h = now - timedelta(hours=24)
        last_7d  = now - timedelta(days=7)
        last_30d = now - timedelta(days=30)
        sla_24h = _sla_window(session, last_24h)
        sla_7d  = _sla_window(session, last_7d)
        sla_30d = _sla_window(session, last_30d)
        wh_avg_attempts = _avg_webhook_attempts(session, last_7d)
        wh_pending      = _webhook_pending_backlog(session)

        funnel_24h = _auth_funnel(session, last_24h)
        funnel_7d  = _auth_funnel(session, last_7d)
        funnel_30d = _auth_funnel(session, last_30d)

        binding_24h = _binding_lifecycle(session, last_24h)
        binding_7d  = _binding_lifecycle(session, last_7d)
        binding_30d = _binding_lifecycle(session, last_30d)

        engage_24h = _engagement_window(session, last_24h)
        engage_7d  = _engagement_window(session, last_7d)
        engage_30d = _engagement_window(session, last_30d)

        reject_24h = _rejections_window(session, last_24h)
        reject_7d  = _rejections_window(session, last_7d)
        reject_30d = _rejections_window(session, last_30d)

        pushes_24h = sla_24h["pushes"]
        pushes_7d  = sla_7d["pushes"]
        replies_24h = sla_24h["webhooks"]

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

    # ── SLA table ────────────────────────────────────────────────────────────
    def _pct(x: Optional[float]) -> str:
        return "—" if x is None else f"{x:.1f}%"

    def _classify(rate: Optional[float], targets=(99.0, 95.0)) -> str:
        """Color hint based on SLA. Targets: ≥99 green, ≥95 amber, else red."""
        if rate is None:
            return "n-na"
        if rate >= targets[0]:
            return "n-ok"
        if rate >= targets[1]:
            return "n-warn"
        return "n-bad"

    sla_rows: list[tuple[str, str, str, str, str]] = [
        ("Push delivery rate",
         f"<span class='{_classify(sla_24h['push_delivery_rate'])}'>{_pct(sla_24h['push_delivery_rate'])}</span>",
         f"<span class='{_classify(sla_7d['push_delivery_rate'])}'>{_pct(sla_7d['push_delivery_rate'])}</span>",
         f"<span class='{_classify(sla_30d['push_delivery_rate'])}'>{_pct(sla_30d['push_delivery_rate'])}</span>",
         "APNs delivered / sent. Targets: 99% / 95%."),
        ("Webhook delivery rate",
         f"<span class='{_classify(sla_24h['webhook_delivery_rate'])}'>{_pct(sla_24h['webhook_delivery_rate'])}</span>",
         f"<span class='{_classify(sla_7d['webhook_delivery_rate'])}'>{_pct(sla_7d['webhook_delivery_rate'])}</span>",
         f"<span class='{_classify(sla_30d['webhook_delivery_rate'])}'>{_pct(sla_30d['webhook_delivery_rate'])}</span>",
         "Webhook posted to agent (excludes mark-as-read). Includes retries."),
        ("Reply rate",
         _pct(sla_24h['reply_rate']),
         _pct(sla_7d['reply_rate']),
         _pct(sla_30d['reply_rate']),
         "User reply / push sent. Engagement health, not a hard SLA."),
        ("Pushes failed",
         f"{sla_24h['pushes_failed']}",
         f"{sla_7d['pushes_failed']}",
         f"{sla_30d['pushes_failed']}",
         "PushMessage with status=failed (APNs rejection)."),
        ("Webhooks failed",
         f"{sla_24h['webhooks_failed']}",
         f"{sla_7d['webhooks_failed']}",
         f"{sla_30d['webhooks_failed']}",
         "Webhook hit retry cap and gave up."),
    ]
    sla_table_html = (
        "<table>"
        "<thead><tr>"
        "<th>SLA metric</th><th class='num'>24h</th><th class='num'>7d</th><th class='num'>30d</th>"
        "<th class='aux'>note</th>"
        "</tr></thead><tbody>"
        + "".join(
            f"<tr><td>{name}</td>"
            f"<td class='num'>{v24}</td>"
            f"<td class='num'>{v7}</td>"
            f"<td class='num'>{v30}</td>"
            f"<td class='aux'>{note}</td></tr>"
            for name, v24, v7, v30, note in sla_rows
        )
        + "</tbody></table>"
    )

    pending_color = "n-ok" if wh_pending == 0 else ("n-warn" if wh_pending < 5 else "n-bad")
    sla_extra_html = (
        f"<div class='kvrow'>"
        f"<div class='kv'><span class='k'>Webhook pending backlog</span>"
        f"<span class='v {pending_color}'>{wh_pending}</span>"
        f"<span class='aux'>0 = healthy. Persistent &gt; 0 means an agent endpoint is unreachable.</span></div>"
        f"<div class='kv'><span class='k'>Avg webhook attempts (7d)</span>"
        f"<span class='v'>{('—' if wh_avg_attempts is None else f'{wh_avg_attempts:.2f}')}</span>"
        f"<span class='aux'>1.0 = first try always succeeds. Higher = flaky agents.</span></div>"
        f"</div>"
    )

    # ── Auth funnel table ────────────────────────────────────────────────────
    def _funnel_row(label: str, key: str, fmt=str, note: str = "") -> str:
        v24 = funnel_24h[key]
        v7  = funnel_7d[key]
        v30 = funnel_30d[key]
        return (f"<tr><td>{label}</td>"
                f"<td class='num'>{fmt(v24)}</td>"
                f"<td class='num'>{fmt(v7)}</td>"
                f"<td class='num'>{fmt(v30)}</td>"
                f"<td class='aux'>{note}</td></tr>")

    funnel_html = (
        "<table><thead><tr>"
        "<th>Auth funnel</th><th class='num'>24h</th><th class='num'>7d</th>"
        "<th class='num'>30d</th><th class='aux'>note</th>"
        "</tr></thead><tbody>"
        + _funnel_row("Auth links created",  "created", note="Agent called /v1/agents/auth-links or /authorize/initiate.")
        + _funnel_row("Auth links used (bound)", "used", note="User completed Authorize tap → binding created.")
        + _funnel_row("Conversion rate", "conversion_rate", _pct, note="Users who saw an auth link and actually bound. Target ≥ 70%.")
        + _funnel_row("Expired without use", "expired_unused", note="Token went past 30-min TTL; user never tapped.")
        + "</tbody></table>"
    )

    # ── Binding lifecycle table ──────────────────────────────────────────────
    def _net_cell(value: int) -> str:
        cls = "n-ok" if value >= 0 else "n-bad"
        return f"<td class='num'><span class='{cls}'>{value:+d}</span></td>"

    binding_html = (
        "<table><thead><tr>"
        "<th>Binding lifecycle</th><th class='num'>24h</th><th class='num'>7d</th>"
        "<th class='num'>30d</th><th class='aux'>note</th>"
        "</tr></thead><tbody>"
        + f"<tr><td>New bindings</td>"
          f"<td class='num'>{binding_24h['new']}</td>"
          f"<td class='num'>{binding_7d['new']}</td>"
          f"<td class='num'>{binding_30d['new']}</td>"
          f"<td class='aux'>Authorize tap → binding row created (active).</td></tr>"
        + f"<tr><td>Revocations</td>"
          f"<td class='num'>{binding_24h['revoked']}</td>"
          f"<td class='num'>{binding_7d['revoked']}</td>"
          f"<td class='num'>{binding_30d['revoked']}</td>"
          f"<td class='aux'>User swiped left → revoke. Includes deleted accounts.</td></tr>"
        + "<tr><td>Net change</td>"
          + _net_cell(binding_24h['net'])
          + _net_cell(binding_7d['net'])
          + _net_cell(binding_30d['net'])
          + "<td class='aux'>new − revoked. Negative over 30d = churn.</td></tr>"
        + "</tbody></table>"
    )

    # ── Engagement table ─────────────────────────────────────────────────────
    engage_html = (
        "<table><thead><tr>"
        "<th>Engagement</th><th class='num'>24h</th><th class='num'>7d</th>"
        "<th class='num'>30d</th><th class='aux'>note</th>"
        "</tr></thead><tbody>"
        + f"<tr><td>Active users</td>"
          f"<td class='num'>{engage_24h['active_users']}</td>"
          f"<td class='num'>{engage_7d['active_users']}</td>"
          f"<td class='num'>{engage_30d['active_users']}</td>"
          f"<td class='aux'>Distinct users with at least one app_opened event.</td></tr>"
        + f"<tr><td>Bulk mark-as-read</td>"
          f"<td class='num'>{engage_24h['bulk_marked_read']}</td>"
          f"<td class='num'>{engage_7d['bulk_marked_read']}</td>"
          f"<td class='num'>{engage_30d['bulk_marked_read']}</td>"
          f"<td class='aux'>Times users hit '一键已读'. High → users feel pings are noise.</td></tr>"
        + f"<tr><td>Delete-account canceled</td>"
          f"<td class='num'>{engage_24h['deletes_canceled']}</td>"
          f"<td class='num'>{engage_7d['deletes_canceled']}</td>"
          f"<td class='num'>{engage_30d['deletes_canceled']}</td>"
          f"<td class='aux'>Users who opened the delete dialog but backed out.</td></tr>"
        + "</tbody></table>"
    )

    # ── Rejections table ─────────────────────────────────────────────────────
    reject_html = (
        "<table><thead><tr>"
        "<th>Push rejections</th><th class='num'>24h</th><th class='num'>7d</th>"
        "<th class='num'>30d</th><th class='aux'>note</th>"
        "</tr></thead><tbody>"
        + f"<tr><td>USER_MUTED (app-wide DND)</td>"
          f"<td class='num'>{reject_24h['user_muted']}</td>"
          f"<td class='num'>{reject_7d['user_muted']}</td>"
          f"<td class='num'>{reject_30d['user_muted']}</td>"
          f"<td class='aux'>Pushes blocked because user has global DND on.</td></tr>"
        + f"<tr><td>AGENT_MUTED (per-agent silence)</td>"
          f"<td class='num'>{reject_24h['agent_muted']}</td>"
          f"<td class='num'>{reject_7d['agent_muted']}</td>"
          f"<td class='num'>{reject_30d['agent_muted']}</td>"
          f"<td class='aux'>Pushes blocked because user muted that specific agent.</td></tr>"
        + f"<tr><td>AGENT_QUOTA_EXCEEDED</td>"
          f"<td class='num'>{reject_24h['quota_exceeded']}</td>"
          f"<td class='num'>{reject_7d['quota_exceeded']}</td>"
          f"<td class='num'>{reject_30d['quota_exceeded']}</td>"
          f"<td class='aux'>Pushes blocked because agent hit free-tier monthly cap.</td></tr>"
        + "</tbody></table>"
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
  .section {{ font-size: 11px; font-weight: 600; letter-spacing: 1.5px;
             color: #8B8580; text-transform: uppercase;
             font-family: ui-monospace, "SF Mono", Menlo, monospace;
             margin: 36px 0 10px; }}
  th {{ font-size: 11px; letter-spacing: 0.5px; color: #8B8580;
        font-weight: 600; text-transform: uppercase; }}
  th.num, td.num {{ text-align: right; }}
  th.aux, td.aux {{ width: 38%; }}
  .n-ok {{ color: #2F855A; }}
  .n-warn {{ color: #C77A1F; }}
  .n-bad {{ color: #B23A48; }}
  .n-na {{ color: #8B8580; }}
  .kvrow {{ display: grid; grid-template-columns: 1fr 1fr; gap: 16px;
           margin: 14px 0 6px; }}
  .kv {{ background: #FAF6EC; border: 1px solid #E8E2D5; border-radius: 10px;
         padding: 12px 14px; display: flex; flex-direction: column; gap: 4px; }}
  .kv .k {{ font-size: 10px; font-weight: 600; letter-spacing: 1.2px;
            color: #8B8580; text-transform: uppercase;
            font-family: ui-monospace, "SF Mono", Menlo, monospace; }}
  .kv .v {{ font-size: 22px; font-weight: 700; font-variant-numeric: tabular-nums; }}
  .kv .aux {{ font-size: 11px; color: #8B8580; line-height: 1.4; }}
</style></head>
<body>
  <h1>HeadsUp · Admin</h1>
  <div class='meta'>generated {datetime.utcnow().strftime('%Y-%m-%d %H:%M UTC')}</div>

  <div class='section'>Totals</div>
  <table>{rows_html}</table>

  <div class='section'>Service health · SLA</div>
  {sla_table_html}
  {sla_extra_html}

  <div class='section'>Auth funnel</div>
  {funnel_html}

  <div class='section'>Binding lifecycle</div>
  {binding_html}

  <div class='section'>Engagement</div>
  {engage_html}

  <div class='section'>Push rejections (limits triggered)</div>
  {reject_html}

  <div class='section'>Trends · last 14d</div>
  {sparks_html}

  <div class='footer'>Read-only. Refresh the page for fresh numbers.</div>
</body></html>"""
