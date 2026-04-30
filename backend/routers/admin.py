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
    SupporterCode,
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


def _top_agent_distribution(session: Session) -> list[dict]:
    """Bucket active bindings by which "famous" agent name the agent has,
    so we can see how the user base is split between Claude Code / Codex /
    Hermes / OpenClaw / "other". Match is case-insensitive substring on
    the agent name, mirroring services/agent_branding.default_accent_for.

    Returns a list ordered by binding count desc, with a final "其他 / Other"
    bucket aggregating everything else. No-binding agents are skipped.
    """
    rows = session.exec(
        select(Agent.id, Agent.name).where(
            Agent.id.in_(
                select(AgentUserBinding.agent_id).where(
                    AgentUserBinding.status == "active"
                )
            )
        )
    ).all()
    # Count active bindings per agent
    binding_counts: dict[str, int] = {}
    for r in rows:
        agent_id = r[0] if isinstance(r, tuple) else r.id
        n = _count(
            session, AgentUserBinding,
            AgentUserBinding.agent_id == agent_id,
            AgentUserBinding.status == "active",
        )
        binding_counts[agent_id] = n

    # Bucket by known name pattern
    buckets: dict[str, int] = {
        "Claude Code": 0,
        "Codex": 0,
        "Hermes": 0,
        "OpenClaw": 0,
        "其他 / Other": 0,
    }
    for r in rows:
        agent_id = r[0] if isinstance(r, tuple) else r.id
        name_raw = (r[1] if isinstance(r, tuple) else r.name) or ""
        name = name_raw.lower()
        n = binding_counts.get(agent_id, 0)
        if "claude" in name:
            buckets["Claude Code"] += n
        elif "codex" in name:
            buckets["Codex"] += n
        elif "hermes" in name:
            buckets["Hermes"] += n
        elif "openclaw" in name or "open claw" in name:
            buckets["OpenClaw"] += n
        else:
            buckets["其他 / Other"] += n

    return [
        {"name": k, "count": v}
        for k, v in sorted(buckets.items(), key=lambda kv: kv[1], reverse=True)
        if v > 0 or k != "其他 / Other"  # always show the 4 known names
    ]


# Mapping product_id → gross USD price. Mirrors HeadsUp.storekit + the
# tiers picked in App Store Connect. Update both when prices change.
TIP_USD = {
    "md.headsup.app.tip.small":  0.99,
    "md.headsup.app.tip.medium": 3.99,
    "md.headsup.app.tip.large": 19.99,
}
TIP_LABEL = {
    "md.headsup.app.tip.small":  "Small (¥6 / $0.99)",
    "md.headsup.app.tip.medium": "Medium (¥28 / $3.99)",
    "md.headsup.app.tip.large":  "Large (¥128 / $19.99)",
}


def _revenue_window(session: Session, since: datetime) -> dict:
    """Sum Tip Jar IAP gross revenue over the window.

    Pulls Event rows with kind='iap_purchased', reads each meta.product_id,
    multiplies by the static USD price table. Apple's 15-30% cut is NOT
    deducted — we report gross because the cut varies (15% under Apple's
    Small Business Program, 30% otherwise). Net is up to the user to
    annotate later if useful.
    """
    rows = session.exec(
        select(Event.meta).where(
            Event.kind == "iap_purchased",
            Event.created_at >= since,
        )
    ).all()
    by_product: dict[str, dict] = {pid: {"count": 0, "usd": 0.0} for pid in TIP_USD}
    for r in rows:
        meta_raw = r if not isinstance(r, tuple) else r[0]
        if not meta_raw:
            continue
        try:
            import json as _json
            meta = _json.loads(meta_raw) if isinstance(meta_raw, str) else meta_raw
        except Exception:
            continue
        pid = (meta or {}).get("product_id")
        if pid not in TIP_USD:
            continue
        by_product[pid]["count"] += 1
        by_product[pid]["usd"] += TIP_USD[pid]
    total_count = sum(b["count"] for b in by_product.values())
    total_usd   = sum(b["usd"]   for b in by_product.values())
    return {
        "count": total_count,
        "usd": total_usd,
        "by_product": by_product,
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

        agent_buckets = _top_agent_distribution(session)

        revenue_24h = _revenue_window(session, last_24h)
        revenue_7d  = _revenue_window(session, last_7d)
        revenue_30d = _revenue_window(session, last_30d)
        revenue_all = _revenue_window(session, datetime(1970, 1, 1))

        pushes_24h = sla_24h["pushes"]
        pushes_7d  = sla_7d["pushes"]
        replies_24h = sla_24h["webhooks"]

        dau = _distinct_actors_per_day(session, "app_opened", 7)
        push_per_day  = _events_per_day(session, "push_sent", 14)
        reply_per_day = _events_per_day(session, "push_replied", 14)
        auth_per_day  = _events_per_day(session, "agent_authorized", 14)

        reply_rate = (replies_total / pushes_total * 100.0) if pushes_total else 0.0

    rows = []
    rows.append(("Agent 总数",        agents_total,    None))
    rows.append(("用户总数",          users_total,     None))
    rows.append(("活跃绑定",          bindings_total,  None))
    rows.append(("推送总数",          pushes_total,    f"24小时: {pushes_24h} · 7天: {pushes_7d}"))
    rows.append(("回复总数",          replies_total,   f"24小时: {replies_24h}"))
    rows.append(("回复率",            f"{reply_rate:.1f}%", None))

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

    def _classify_webhook(rate: Optional[float]) -> str:
        """Webhook delivery rate is only a real SLA breach when there's
        actually stuck retry work (backlog > 0). A clean 0% with backlog 0
        just means agents consume via SSE / polling, not webhook — that's
        fine, not a fault. Keeping it red there cried wolf and trained
        operators to ignore the dashboard."""
        if rate is None:
            return "n-na"
        if wh_pending == 0:
            return "n-ok"   # de-fanged: no stuck work means no fault
        return _classify(rate)

    sla_rows: list[tuple[str, str, str, str, str]] = [
        ("推送投递率",
         f"<span class='{_classify(sla_24h['push_delivery_rate'])}'>{_pct(sla_24h['push_delivery_rate'])}</span>",
         f"<span class='{_classify(sla_7d['push_delivery_rate'])}'>{_pct(sla_7d['push_delivery_rate'])}</span>",
         f"<span class='{_classify(sla_30d['push_delivery_rate'])}'>{_pct(sla_30d['push_delivery_rate'])}</span>",
         "APNs 投递成功 / 已发出。绿 ≥99%, 黄 ≥95%, 红 <95%。"),
        ("Webhook 投递率",
         f"<span class='{_classify_webhook(sla_24h['webhook_delivery_rate'])}'>{_pct(sla_24h['webhook_delivery_rate'])}</span>",
         f"<span class='{_classify_webhook(sla_7d['webhook_delivery_rate'])}'>{_pct(sla_7d['webhook_delivery_rate'])}</span>",
         f"<span class='{_classify_webhook(sla_30d['webhook_delivery_rate'])}'>{_pct(sla_30d['webhook_delivery_rate'])}</span>",
         "Webhook 推到 agent。0% + 积压 0 = agent 走 SSE/polling，不算故障；只有积压 >0 才该担心。"),
        ("回复率",
         _pct(sla_24h['reply_rate']),
         _pct(sla_7d['reply_rate']),
         _pct(sla_30d['reply_rate']),
         "用户回复数 / 推送数。粘性指标，不是硬 SLA。"),
        ("推送失败数",
         f"{sla_24h['pushes_failed']}",
         f"{sla_7d['pushes_failed']}",
         f"{sla_30d['pushes_failed']}",
         "PushMessage status=failed（APNs 拒收）。"),
        ("Webhook 失败数",
         f"{sla_24h['webhooks_failed']}",
         f"{sla_7d['webhooks_failed']}",
         f"{sla_30d['webhooks_failed']}",
         "重试上限耗尽后放弃投递的 webhook。"),
    ]
    sla_table_html = (
        "<table>"
        "<thead><tr>"
        "<th>SLA 指标</th><th class='num'>24小时</th><th class='num'>7天</th><th class='num'>30天</th>"
        "<th class='aux'>说明</th>"
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
        f"<div class='kv'><span class='k'>Webhook 待重试积压</span>"
        f"<span class='v {pending_color}'>{wh_pending}</span>"
        f"<span class='aux'>0 = 健康。持续 &gt; 0 表示某 agent 的 webhook URL 不可达。</span></div>"
        f"<div class='kv'><span class='k'>Webhook 平均重试次数 (7天)</span>"
        f"<span class='v'>{('—' if wh_avg_attempts is None else f'{wh_avg_attempts:.2f}')}</span>"
        f"<span class='aux'>1.0 = 首次就成功。越高代表 agent 端越不稳定。</span></div>"
        f"</div>"
    )

    # ── Top agents distribution ─────────────────────────────────────────────
    if agent_buckets:
        max_count = max((b["count"] for b in agent_buckets), default=1) or 1
        agent_dist_html = (
            "<table><thead><tr>"
            "<th>Agent 类型</th><th class='num'>活跃绑定</th>"
            "<th class='aux'>占比</th>"
            "</tr></thead><tbody>"
            + "".join(
                f"<tr><td>{b['name']}</td>"
                f"<td class='num'>{b['count']}</td>"
                f"<td class='aux'>"
                f"<div style='display:flex;align-items:center;gap:8px;'>"
                f"<div style='flex:1;height:6px;background:#E8E2D5;border-radius:3px;overflow:hidden;'>"
                f"<div style='width:{(b['count']/max_count*100):.0f}%;height:100%;background:#6B60A8;'></div>"
                f"</div>"
                f"<span style='font-variant-numeric:tabular-nums;min-width:42px;text-align:right;'>"
                f"{(b['count']/sum(x['count'] for x in agent_buckets)*100 if sum(x['count'] for x in agent_buckets) else 0):.0f}%"
                f"</span>"
                f"</div>"
                f"</td></tr>"
                for b in agent_buckets
            )
            + "</tbody></table>"
        )
    else:
        agent_dist_html = "<p class='aux'>暂无 agent 绑定数据。</p>"

    # ── Revenue · Tip Jar (IAP) ─────────────────────────────────────────────
    def _money(usd: float) -> str:
        return f"${usd:,.2f}"

    revenue_summary_html = (
        "<table><thead><tr>"
        "<th>窗口</th><th class='num'>笔数</th><th class='num'>毛收入 (USD)</th>"
        "<th class='aux'>说明</th>"
        "</tr></thead><tbody>"
        f"<tr><td>累计</td><td class='num'>{revenue_all['count']}</td>"
        f"<td class='num'>{_money(revenue_all['usd'])}</td>"
        f"<td class='aux'>Apple 抽成 15-30% 后是净收入(数字未扣)</td></tr>"
        f"<tr><td>30 天</td><td class='num'>{revenue_30d['count']}</td>"
        f"<td class='num'>{_money(revenue_30d['usd'])}</td><td class='aux'></td></tr>"
        f"<tr><td>7 天</td><td class='num'>{revenue_7d['count']}</td>"
        f"<td class='num'>{_money(revenue_7d['usd'])}</td><td class='aux'></td></tr>"
        f"<tr><td>24 小时</td><td class='num'>{revenue_24h['count']}</td>"
        f"<td class='num'>{_money(revenue_24h['usd'])}</td><td class='aux'></td></tr>"
        "</tbody></table>"
    )
    # Per-product breakdown for the all-time window
    bp = revenue_all["by_product"]
    revenue_breakdown_html = (
        "<table><thead><tr>"
        "<th>档位</th><th class='num'>累计笔数</th><th class='num'>累计毛收 (USD)</th>"
        "</tr></thead><tbody>"
        + "".join(
            f"<tr><td>{TIP_LABEL[pid]}</td>"
            f"<td class='num'>{bp[pid]['count']}</td>"
            f"<td class='num'>{_money(bp[pid]['usd'])}</td></tr>"
            for pid in ["md.headsup.app.tip.small",
                        "md.headsup.app.tip.medium",
                        "md.headsup.app.tip.large"]
        )
        + "</tbody></table>"
    )
    revenue_html = revenue_summary_html + revenue_breakdown_html

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
        "<th>授权漏斗</th><th class='num'>24小时</th><th class='num'>7天</th>"
        "<th class='num'>30天</th><th class='aux'>说明</th>"
        "</tr></thead><tbody>"
        + _funnel_row("授权链接创建",  "created", note="agent 调用 /v1/agents/auth-links 或 /authorize/initiate。")
        + _funnel_row("链接被使用 (已绑定)", "used", note="用户完成 Authorize 点击 → 创建绑定。")
        + _funnel_row("转化率", "conversion_rate", _pct, note="拿到授权链接后真的去绑定的用户占比。目标 ≥ 70%。")
        + _funnel_row("过期未用", "expired_unused", note="token 超出 30 分钟 TTL,用户没点。")
        + "</tbody></table>"
    )

    # ── Binding lifecycle table ──────────────────────────────────────────────
    def _net_cell(value: int) -> str:
        cls = "n-ok" if value >= 0 else "n-bad"
        return f"<td class='num'><span class='{cls}'>{value:+d}</span></td>"

    binding_html = (
        "<table><thead><tr>"
        "<th>绑定生命周期</th><th class='num'>24小时</th><th class='num'>7天</th>"
        "<th class='num'>30天</th><th class='aux'>说明</th>"
        "</tr></thead><tbody>"
        + f"<tr><td>新增绑定</td>"
          f"<td class='num'>{binding_24h['new']}</td>"
          f"<td class='num'>{binding_7d['new']}</td>"
          f"<td class='num'>{binding_30d['new']}</td>"
          f"<td class='aux'>用户点 Authorize → 创建 active binding。</td></tr>"
        + f"<tr><td>撤销数</td>"
          f"<td class='num'>{binding_24h['revoked']}</td>"
          f"<td class='num'>{binding_7d['revoked']}</td>"
          f"<td class='num'>{binding_30d['revoked']}</td>"
          f"<td class='aux'>用户左滑撤销;含删账号造成的撤销。</td></tr>"
        + "<tr><td>净变化</td>"
          + _net_cell(binding_24h['net'])
          + _net_cell(binding_7d['net'])
          + _net_cell(binding_30d['net'])
          + "<td class='aux'>新增 − 撤销。30 天为负 = 流失。</td></tr>"
        + "</tbody></table>"
    )

    # ── Engagement table ─────────────────────────────────────────────────────
    engage_html = (
        "<table><thead><tr>"
        "<th>用户活跃</th><th class='num'>24小时</th><th class='num'>7天</th>"
        "<th class='num'>30天</th><th class='aux'>说明</th>"
        "</tr></thead><tbody>"
        + f"<tr><td>活跃用户</td>"
          f"<td class='num'>{engage_24h['active_users']}</td>"
          f"<td class='num'>{engage_7d['active_users']}</td>"
          f"<td class='num'>{engage_30d['active_users']}</td>"
          f"<td class='aux'>有过 app_opened 事件的不同用户数。</td></tr>"
        + f"<tr><td>一键已读次数</td>"
          f"<td class='num'>{engage_24h['bulk_marked_read']}</td>"
          f"<td class='num'>{engage_7d['bulk_marked_read']}</td>"
          f"<td class='num'>{engage_30d['bulk_marked_read']}</td>"
          f"<td class='aux'>用户用 \"一键已读\" 的次数。高 = 用户觉得推送太烦。</td></tr>"
        + f"<tr><td>删账号又取消</td>"
          f"<td class='num'>{engage_24h['deletes_canceled']}</td>"
          f"<td class='num'>{engage_7d['deletes_canceled']}</td>"
          f"<td class='num'>{engage_30d['deletes_canceled']}</td>"
          f"<td class='aux'>打开删账号对话框但点取消的人。</td></tr>"
        + "</tbody></table>"
    )

    # ── Rejections table ─────────────────────────────────────────────────────
    reject_html = (
        "<table><thead><tr>"
        "<th>推送被拒</th><th class='num'>24小时</th><th class='num'>7天</th>"
        "<th class='num'>30天</th><th class='aux'>说明</th>"
        "</tr></thead><tbody>"
        + f"<tr><td>USER_MUTED (用户全局 DND)</td>"
          f"<td class='num'>{reject_24h['user_muted']}</td>"
          f"<td class='num'>{reject_7d['user_muted']}</td>"
          f"<td class='num'>{reject_30d['user_muted']}</td>"
          f"<td class='aux'>用户开了全局免打扰。</td></tr>"
        + f"<tr><td>AGENT_MUTED (单 agent 静音)</td>"
          f"<td class='num'>{reject_24h['agent_muted']}</td>"
          f"<td class='num'>{reject_7d['agent_muted']}</td>"
          f"<td class='num'>{reject_30d['agent_muted']}</td>"
          f"<td class='aux'>用户单独把这个 agent 静音了。</td></tr>"
        + f"<tr><td>AGENT_QUOTA_EXCEEDED (配额耗尽)</td>"
          f"<td class='num'>{reject_24h['quota_exceeded']}</td>"
          f"<td class='num'>{reject_7d['quota_exceeded']}</td>"
          f"<td class='num'>{reject_30d['quota_exceeded']}</td>"
          f"<td class='aux'>agent 用完免费层月度配额。</td></tr>"
        + "</tbody></table>"
    )

    sparks_html = "".join([
        _series_html("DAU (打开 app 用户)",   dau),
        _series_html("每日推送量",            push_per_day),
        _series_html("每日回复量",            reply_per_day),
        _series_html("每日新增绑定",          auth_per_day),
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
  <h1>HeadsUp · 后台</h1>
  <div class='meta'>生成于 {datetime.utcnow().strftime('%Y-%m-%d %H:%M UTC')}</div>

  <div class='section'>总览</div>
  <table>{rows_html}</table>

  <div class='section'>服务健康度 · SLA</div>
  {sla_table_html}
  {sla_extra_html}

  <div class='section'>主流 Agent 分布</div>
  {agent_dist_html}

  <div class='section'>Tip Jar · 收入</div>
  {revenue_html}

  <div class='section'>授权漏斗</div>
  {funnel_html}

  <div class='section'>绑定生命周期</div>
  {binding_html}

  <div class='section'>用户活跃</div>
  {engage_html}

  <div class='section'>推送拦截</div>
  {reject_html}

  <div class='section'>趋势 · 最近 14 天</div>
  {sparks_html}

  <div class='footer'>只读。刷新页面看最新数据。</div>
</body></html>"""


@router.post("/admin/backfill-badges")
def admin_backfill_badges(token: str = Query(default="")):
    """Replay badge evaluators against all historical agents/users/messages.

    Awards any badges that were missed because the agent/user pre-dated a
    given evaluator. Idempotent — safe to run multiple times. Suppresses
    celebration pushes/webhooks (marks awarded badges as already notified).
    """
    _require_admin(token)
    from services.badges import backfill_all
    with Session(engine) as session:
        counts = backfill_all(session)
    return counts
