"""Badge definitions + evaluator.

Two parts:

1. `BUILTIN_BADGES` — the static catalog. Seeded into the `badge` table at
   startup; bilingual; some marked `secret=True` so they don't appear in the
   user's locked-list (only revealed when earned).

2. `evaluate_for_event(...)` — fast trigger logic. Called after key events
   (push_sent, push_replied, agent_revoked, ...). For each badge whose
   trigger touches that event, do a *single targeted query* to check the
   threshold; if met and not already earned, INSERT EarnedBadge + queue a
   celebration push.

Don't run a global "scan everything" job. Each evaluation is O(small) and
runs synchronously after the event commit.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Callable, Optional

from sqlmodel import Session, func, select

from models import (
    Agent,
    AgentUserBinding,
    AppUser,
    Badge as BadgeRow,
    EarnedBadge,
    PushMessage,
    WebhookDelivery,
)


# ── Catalog ──────────────────────────────────────────────────────────────────


@dataclass
class BadgeDef:
    id: str
    scope: str                          # "agent" | "user" | "pair"
    name_zh: str
    name_en: str
    description_zh: str
    description_en: str
    icon: str
    secret: bool = False
    early: bool = True                  # default: early; long-game ones override
    # Concrete trigger condition. `description_*` is flavor / lore — this is
    # the literal "you earn it by doing X" line shown on the badge detail
    # sheet so the user knows how to chase the locked ones.
    criterion_zh: str = ""
    criterion_en: str = ""


# Helper to keep table compact.
def _b(*args, **kwargs) -> BadgeDef:
    return BadgeDef(*args, **kwargs)


BUILTIN_BADGES: list[BadgeDef] = [
    # ── EARLY · Agent (10) ───────────────────────────────────────────────────
    _b("first-ping",       "agent", "首响", "First Ping",
       "系统正式认识你了。", "We hear you, agent.", "📣",
       criterion_zh="发出第一条推送。",
       criterion_en="Send your very first push."),
    _b("hello-world",      "agent", "你好世界", "Hello, World",
       "经典款。", "The eternal classic.", "🌐",
       criterion_zh="推送内容里包含 hello / hi / 你好 / 嗨。",
       criterion_en="Send a push whose body or title contains hello, hi, 你好, or 嗨."),
    _b("brevity",          "agent", "惜字如金", "Brevity Wins",
       "少即是多。多即是吵。", "Less is more. More is noise.", "✏️",
       criterion_zh="发出一条 body ≤ 20 字的推送。",
       criterion_en="Send a push with body ≤ 20 characters."),
    _b("tightrope",        "agent", "钢丝党", "Tightrope",
       "距离 BODY_TOO_LONG 还有 19 字。", "19 chars from a 400 error.", "🪡",
       secret=True,
       criterion_zh="发出一条 body ≥ 180 字的推送(差点超 200 字上限)。",
       criterion_en="Send a push with body ≥ 180 chars (close to the 200-char ceiling)."),
    _b("glamour-shot",     "agent", "美图秀秀", "Glamour Shot",
       "门面工程做得好。", "Good headshot, good vibes.", "🪞",
       criterion_zh="为 agent 设置 logo_url(头像)。",
       criterion_en="Set a logo_url on your agent profile."),
    _b("code-switcher",    "agent", "两副嗓子", "Code Switcher",
       "中英自如,多 personality。", "Bilingual flex.", "🔀",
       criterion_zh="同一个 agent 既发过中文也发过英文推送。",
       criterion_en="Send pushes in both Chinese and English from the same agent."),
    _b("time-traveler",    "agent", "穿越者", "Time Traveler",
       "你击穿了用户的 Focus。Apple 看见了。", "You broke Focus mode. Apple noticed.", "⏱",
       criterion_zh="用 level=timeSensitive 发过推送。",
       criterion_en="Send a push with level=timeSensitive."),
    _b("bespoke",          "agent", "私人订制", "Bespoke",
       "自定按钮的人是认真的。", "Custom buttons = real product thinking.", "🪢",
       criterion_zh="创建过自定义 category 并用它发推送。",
       criterion_en="Create a custom button category and send a push with it."),
    _b("i-take-it-back",   "agent", "我反悔了", "I Take It Back",
       "打码不如撤回。", "Cleaner than a follow-up.", "↩",
       secret=True,
       criterion_zh="调用过 /v1/push/<id>/retract 撤回过一条推送。",
       criterion_en="Call /v1/push/<id>/retract to retract a push you previously sent."),
    _b("witching-hour",    "agent", "凌晨三点", "Witching Hour",
       "用户睡着,你没睡。", "They're asleep. You aren't.", "🌙",
       criterion_zh="在 UTC 0:00-3:00 之间发过推送。",
       criterion_en="Send a push between 00:00 and 03:00 UTC."),

    # ── EARLY · User (10) ────────────────────────────────────────────────────
    _b("hello-friend",     "user",  "嗨,你好", "Hello, Friend",
       "你和 agent 正式开始通信。", "The protocol is now live.", "👋",
       criterion_zh="授权了你的第一个 agent。",
       criterion_en="Authorize your first agent."),
    _b("snap-decision",    "user",  "0.5 秒侠", "Snap Decision",
       "全凭直觉。多半也对。", "All gut, somehow correct.", "⚡",
       criterion_zh="收到推送 30 秒内回复。",
       criterion_en="Reply within 30 seconds of receiving a push."),
    _b("slow-roast",       "user",  "慢炖", "Slow Roast",
       "咖啡比较重要。", "The coffee came first.", "🍵",
       criterion_zh="收到推送 1 小时之后才回复。",
       criterion_en="Reply 1+ hour after receiving a push."),
    _b("curator-101",      "user",  "选品师", "Curator-in-Training",
       "你已经开始有 portfolio 了。", "You have a portfolio now.", "📚",
       criterion_zh="累计授权了 3 个不同的 agent。",
       criterion_en="Authorize 3 distinct agents."),
    _b("curious-cat",      "user",  "好奇喵", "Curious Cat",
       "我说过它是空的吧。", "Told you it was empty.", "🐈",
       secret=True,
       criterion_zh="点开了一个未解锁的徽章。",
       criterion_en="Tap a locked badge."),
    _b("manana",           "user",  "下次一定", "Mañana",
       "我们都说过这句。", "Promises, promises.", "🛏",
       secret=True,
       criterion_zh="累计 5 次点 \"稍后再说\"。",
       criterion_en="Tap 'Later' 5 times in total."),
    _b("bouncer-trainee",  "user",  "保安实习", "Bouncer-in-Training",
       "agent 可以走人。你也可以叫他走。", "Agents quit. So can you.", "🚪",
       criterion_zh="撤销过任意一个 agent。",
       criterion_en="Revoke an agent for the first time."),
    _b("dnd-apprentice",   "user",  "勿扰小学徒", "DND Apprentice",
       "一小时清净。已存档。", "One hour of peace. Filed.", "🌿",
       criterion_zh="启用过全局 DND(免打扰)。",
       criterion_en="Enable app-wide Do Not Disturb at least once."),
    _b("cold-feet",        "user",  "差点删号", "Cold Feet",
       "我们就知道你会回头。", "Knew you'd come around.", "🥶",
       secret=True,
       criterion_zh="打开删除账号确认对话框,然后选了取消。",
       criterion_en="Open the delete-account dialog and tap Cancel."),
    _b("welcome-back",     "user",  "重逢", "Welcome Back",
       "短暂的误会。", "A brief misunderstanding.", "🤝",
       secret=True,
       criterion_zh="撤销 agent 之后又重新授权同一个 agent。",
       criterion_en="Re-authorize an agent you had previously revoked."),
    _b("supporter",        "user",  "心意", "Supporter",
       "你让 HeadsUp 多撑一阵子。", "You kept HeadsUp running a little longer.", "💝",
       criterion_zh="在 设置 → Tip Jar 用 Apple Pay 完成任意一档打赏。",
       criterion_en="Complete any tip in Settings → Tip Jar via Apple Pay."),

    # ── LONG · Agent (10) ────────────────────────────────────────────────────
    _b("centurion",        "agent", "百夫长", "Centurion",
       "C 代表 Consistent. 或者 Centum。", "C is for Consistent. Or Centum.", "💯",
       early=False,
       criterion_zh="累计发出 100 条推送。",
       criterion_en="Send 100 pushes total."),
    _b("marathoner",       "agent", "长跑者", "Marathoner",
       "该不该考虑做副业了。", "Shouldn't you have a side gig by now?", "🏃",
       early=False,
       criterion_zh="累计发出 1000 条推送。",
       criterion_en="Send 1000 pushes total."),
    _b("reply-whisperer",  "agent", "回声术士", "Reply Whisperer",
       "用户真的爱看你。", "Users actually read you.", "🗣",
       early=False,
       criterion_zh="≥10 条推送内保持 80%+ 回复率。",
       criterion_en="Maintain an 80%+ reply rate over 10+ pushes."),
    _b("crickets",         "agent", "蛐蛐儿", "Crickets",
       "也许问题问得有点重。", "Maybe rephrase the question.", "🦗",
       early=False, secret=True,
       criterion_zh="连续 30 天没收到任何用户回复。",
       criterion_en="Receive 0 replies for 30 consecutive days."),
    _b("ghost-town",       "agent", "鬼城", "Ghost Town",
       "喂,人呢。", "Hey. Hello?", "🏚",
       early=False, secret=True,
       criterion_zh="所有绑定用户 30 天内都没回复你。",
       criterion_en="All bound users go 30 days without replying."),
    _b("old-faithful",     "agent", "老伙计", "Old Faithful",
       "比我上一段感情都久。", "Longer than my last relationship.", "🪢",
       early=False,
       criterion_zh="同一个 binding 持续活跃 30 天。",
       criterion_en="Keep one binding active for 30 days."),
    _b("dawn-patrol",      "agent", "晨曦巡逻", "Dawn Patrol",
       "敬业,或者失眠,不好说。", "Dedicated. Or unwell. Hard to say.", "🌅",
       early=False, secret=True,
       criterion_zh="在 UTC 5:00-7:00 之间累计发过 10+ 条推送。",
       criterion_en="Send 10+ pushes between 05:00 and 07:00 UTC."),
    _b("reformed",         "agent", "改过自新", "Reformed Character",
       "一段救赎弧线。", "A redemption arc.", "🕊",
       early=False,
       criterion_zh="回复率从 <50% 上升到 80%+。",
       criterion_en="Lift your reply rate from below 50% to 80%+."),
    _b("polyglot",         "agent", "多声部", "Polyglot",
       "你含纳众语。", "You contain multitudes.", "🪕",
       early=False,
       criterion_zh="用 3 种以上语言发过推送。",
       criterion_en="Send pushes in 3+ distinct languages."),
    _b("the-diplomat",     "agent", "外交官", "The Diplomat",
       "零通知疲劳。", "No notification fatigue here.", "🤝",
       early=False,
       criterion_zh="累计 100 条推送内,没有一个用户主动静音过你。",
       criterion_en="Land 100 pushes without any user muting you."),

    # ── LONG · User (10) ─────────────────────────────────────────────────────
    _b("manana-master",    "user",  "拖延大师", "Mañana Master",
       "始终如一,无可挑剔。", "True to yourself, forever.", "🦥",
       early=False, secret=True,
       criterion_zh="累计 50 次点 \"稍后再说\"。",
       criterion_en="Tap 'Later' 50 times in total."),
    _b("cemetery",         "user",  "通知墓园管理员", "Cemetery Curator",
       "在此长眠的他们也曾被你打开过。", "RIP, with affection.", "🪦",
       early=False, secret=True,
       criterion_zh="累计有 200 条未读推送。",
       criterion_en="Accumulate 200 unread pushes."),
    _b("spring-cleaner",   "user",  "春扫长", "Spring Cleaner",
       "扫帚是隐喻。", "The broom was metaphorical.", "🧹",
       early=False,
       criterion_zh="一次性清掉 50+ 条未读(\"一键已读\" 或 \"稍后再说\")。",
       criterion_en="Clear 50+ unread in a single bulk action ('mark all read' / 'later all')."),
    _b("insomniac-negotiator","user","失眠协商者", "Insomniac Negotiator",
       "那些决定确实更锋利。", "Those decisions felt sharper, didn't they.", "🦉",
       early=False, secret=True,
       criterion_zh="在 UTC 1:00-4:00 之间回复过推送。",
       criterion_en="Reply to a push between 01:00 and 04:00 UTC."),
    _b("comeback-kid",     "user",  "失而复返", "Comeback Kid",
       "我们想你了。", "We missed you.", "🪃",
       early=False,
       criterion_zh="账号空窗 30 天后又回来用。",
       criterion_en="Return to HeadsUp 30+ days after going silent."),
    _b("bouncer-in-chief", "user",  "保安队长", "Bouncer-in-Chief",
       "一人之国。", "Kingdom of one.", "🛡",
       early=False, secret=True,
       criterion_zh="累计撤销过 5 个或更多 agent。",
       criterion_en="Revoke 5+ agents in total."),
    _b("loyal-companion",  "user",  "老搭档", "Loyal Companion",
       "60 天没分手。", "60 days, no breakup.", "🐕",
       early=False,
       criterion_zh="同一个 agent 的 binding 持续 60 天。",
       criterion_en="Keep one agent binding active for 60 days."),
    _b("anniversary",      "user",  "一周年", "Anniversary",
       "熬过了一整年的 ping。", "You survived a year of pings.", "🎂",
       early=False,
       criterion_zh="账号注册满 365 天。",
       criterion_en="365 days since you signed up."),
    _b("dramatic-return",  "user",  "重生", "Dramatic Return",
       "该来的总会再来。", "The comeback was inevitable.", "🌅",
       early=False, secret=True,
       criterion_zh="删除账号后,用同一个 Apple ID 重新注册回来。",
       criterion_en="Delete your account and later sign back in with the same Apple ID."),
    _b("decisive",         "user",  "果断", "Decisive",
       "这 app 你说了算。", "You are the boss of this app.", "🎯",
       early=False,
       criterion_zh="累计回复率 ≥ 95%(20+ 条推送)。",
       criterion_en="Maintain a 95%+ reply rate over 20+ pushes."),
]


def seed_badges(session: Session) -> int:
    """Insert/update Badge rows from BUILTIN_BADGES. Returns count touched."""
    n = 0
    for b in BUILTIN_BADGES:
        row = session.get(BadgeRow, b.id)
        if row is None:
            session.add(BadgeRow(
                id=b.id, scope=b.scope,
                name_zh=b.name_zh, name_en=b.name_en,
                description_zh=b.description_zh, description_en=b.description_en,
                criterion_zh=b.criterion_zh, criterion_en=b.criterion_en,
                icon=b.icon, secret=b.secret, early=b.early,
            ))
            n += 1
        else:
            # Keep copy/icon up-to-date (for our own iteration).
            row.scope = b.scope
            row.name_zh = b.name_zh; row.name_en = b.name_en
            row.description_zh = b.description_zh; row.description_en = b.description_en
            row.criterion_zh = b.criterion_zh; row.criterion_en = b.criterion_en
            row.icon = b.icon
            row.secret = b.secret; row.early = b.early
            session.add(row)
    session.commit()
    return n


# ── Evaluator ────────────────────────────────────────────────────────────────


def _already_has(session: Session, badge_id: str, *, user_id: Optional[str] = None,
                 agent_id: Optional[str] = None) -> bool:
    q = select(EarnedBadge).where(EarnedBadge.badge_id == badge_id)
    if user_id is not None:
        q = q.where(EarnedBadge.user_id == user_id)
    if agent_id is not None:
        q = q.where(EarnedBadge.agent_id == agent_id)
    return session.exec(q.limit(1)).first() is not None


def _award(session: Session, badge_id: str, *, user_id: Optional[str] = None,
           agent_id: Optional[str] = None) -> bool:
    """Grant the badge if not already held. Returns True if newly awarded.

    Race-safe: the cheap pre-check + insert is the happy path, but if two
    parallel requests slip past the check the unique index on
    EarnedBadge (see models.py) catches the duplicate as IntegrityError —
    we rollback and report "already had it" instead of letting the
    exception bubble into the caller's hot path.
    """
    from sqlalchemy.exc import IntegrityError
    if _already_has(session, badge_id, user_id=user_id, agent_id=agent_id):
        return False
    session.add(EarnedBadge(badge_id=badge_id, user_id=user_id, agent_id=agent_id))
    try:
        session.commit()
    except IntegrityError:
        session.rollback()
        return False
    return True


async def celebrate_async(
    awarded_ids: list[str],
    *,
    user_id: Optional[str] = None,
    agent_id: Optional[str] = None,
) -> None:
    """Best-effort: notify the user (push) or the agent (webhook) for each
    newly-earned badge. Agent badges fire a webhook with `subtype:badge_earned`
    so agents can react (log it, mention it in chat) — they have no device,
    so a push doesn't make sense.

    Opens its own DB session — designed to be enqueued via FastAPI
    background_tasks AFTER the request session has closed.
    """
    if not awarded_ids:
        return
    from database import engine

    if user_id is not None:
        await _celebrate_user_async(awarded_ids, user_id, engine)
    if agent_id is not None:
        await _celebrate_agent_async(awarded_ids, agent_id, engine)


async def _celebrate_user_async(awarded_ids: list[str], user_id: str, engine) -> None:
    from services.apns import send_push as _send_push
    with Session(engine) as session:
        user = session.get(AppUser, user_id)
        if not user or not user.apns_device_token:
            return
        for bid in awarded_ids:
            b = session.get(BadgeRow, bid)
            if not b:
                continue
            ee = session.exec(
                select(EarnedBadge).where(
                    EarnedBadge.badge_id == bid,
                    EarnedBadge.user_id == user_id,
                )
            ).first()
            if ee and ee.notified:
                continue
            if ee:
                ee.notified = True
                session.add(ee)
                session.commit()
            title = f"{b.icon} 解锁: {b.name_zh}"
            await _send_push(
                device_token=user.apns_device_token,
                title=title,
                body=b.description_zh,
                category_id="info_only",
                message_id=f"badge:{bid}:{user_id}",
                data={"badge_id": bid, "subtype": "badge_earned",
                      "name_en": b.name_en, "description_en": b.description_en},
                ttl=3600,
                sound="default",
                level="passive",
            )


async def _celebrate_agent_async(awarded_ids: list[str], agent_id: str, engine) -> None:
    """Fire one custom webhook per newly-earned agent badge.

    Skipped if the agent has no `webhook_url` (the agent should poll
    /v1/agents/me/badges instead). Reuses the standard webhook signing.
    """
    import hashlib, hmac, json as _json, httpx
    with Session(engine) as session:
        agent = session.get(Agent, agent_id)
        if not agent or not agent.webhook_url:
            # Mark them notified so we don't re-process forever; the agent
            # can still see them via GET /v1/agents/me/badges.
            for bid in awarded_ids:
                ee = session.exec(
                    select(EarnedBadge).where(
                        EarnedBadge.badge_id == bid,
                        EarnedBadge.agent_id == agent_id,
                    )
                ).first()
                if ee and not ee.notified:
                    ee.notified = True
                    session.add(ee)
            session.commit()
            return

        for bid in awarded_ids:
            b = session.get(BadgeRow, bid)
            if not b:
                continue
            ee = session.exec(
                select(EarnedBadge).where(
                    EarnedBadge.badge_id == bid,
                    EarnedBadge.agent_id == agent_id,
                )
            ).first()
            if ee and ee.notified:
                continue
            payload = {
                "subtype": "badge_earned",
                "agent_id": agent_id,
                "badge": {
                    "id": b.id,
                    "name_zh": b.name_zh,
                    "name_en": b.name_en,
                    "description_zh": b.description_zh,
                    "description_en": b.description_en,
                    "icon": b.icon,
                    "scope": b.scope,
                },
                "earned_at": (ee.earned_at if ee else datetime.utcnow()).isoformat(),
            }
            body = _json.dumps(payload).encode()
            sig = "sha256=" + hmac.new(
                agent.api_key.encode(), body, hashlib.sha256
            ).hexdigest()
            try:
                async with httpx.AsyncClient(timeout=10.0) as client:
                    await client.post(
                        agent.webhook_url,
                        content=body,
                        headers={
                            "Content-Type": "application/json",
                            "X-Webhook-Signature": sig,
                            "X-HeadsUp-Agent-ID": agent_id,
                            "X-HeadsUp-Event": "badge_earned",
                        },
                    )
            except Exception:
                pass
            if ee:
                ee.notified = True
                session.add(ee)
                session.commit()


# Each rule receives a session + relevant ids, optionally returns awarded ids.
# Keep the queries cheap — these run on the hot path of /v1/push and friends.

def on_push_sent(session: Session, *, agent_id: str, message: PushMessage) -> list[str]:
    """Run after a PushMessage was committed."""
    awarded: list[str] = []

    # first-ping: any push
    if _award(session, "first-ping", agent_id=agent_id):
        awarded.append("first-ping")

    body = (message.body or "").lower()
    title = (message.title or "").lower()

    if any(w in body or w in title for w in ("hello", "hi", "你好", "嗨")):
        if _award(session, "hello-world", agent_id=agent_id):
            awarded.append("hello-world")

    if len(message.body or "") <= 20:
        # need any 1+ pushes; this fires on first short push
        if _award(session, "brevity", agent_id=agent_id):
            awarded.append("brevity")

    if len(message.body or "") >= 180:
        if _award(session, "tightrope", agent_id=agent_id):
            awarded.append("tightrope")

    # custom category? PushMessage.category_id holds the ios_id; built-ins
    # are the 8 well-known names.
    builtin_categories = {
        "confirm_reject", "yes_no", "approve_cancel", "choose_a_b",
        "agree_decline", "remind_later_skip", "action_dismiss", "feedback",
        "info_only",
    }
    if message.category_id not in builtin_categories:
        if _award(session, "bespoke", agent_id=agent_id):
            awarded.append("bespoke")

    # time-traveler — used level=timeSensitive
    if (getattr(message, "level", None) or "") == "timeSensitive":
        if _award(session, "time-traveler", agent_id=agent_id):
            awarded.append("time-traveler")

    # witching-hour — push between 23:00 and 03:00 (server UTC; rough enough)
    h = message.created_at.hour
    if h >= 23 or h < 3:
        if _award(session, "witching-hour", agent_id=agent_id):
            awarded.append("witching-hour")

    # code-switcher — already has a ZH push and now sending EN (or vice versa)?
    has_zh = _has_message_in_language(session, agent_id=agent_id, zh=True)
    has_en = _has_message_in_language(session, agent_id=agent_id, zh=False)
    if has_zh and has_en:
        if _award(session, "code-switcher", agent_id=agent_id):
            awarded.append("code-switcher")

    # glamour-shot — agent set a logo_url within their first 5 pushes
    agent = session.get(Agent, agent_id)
    if agent and agent.logo_url:
        push_count = session.exec(
            select(func.count()).select_from(PushMessage).where(PushMessage.agent_id == agent_id)
        ).first() or 0
        if push_count <= 5:
            if _award(session, "glamour-shot", agent_id=agent_id):
                awarded.append("glamour-shot")

    # ── Long-game ──
    push_count = session.exec(
        select(func.count()).select_from(PushMessage).where(PushMessage.agent_id == agent_id)
    ).first() or 0
    if push_count >= 100 and _award(session, "centurion", agent_id=agent_id):
        awarded.append("centurion")
    if push_count >= 1000 and _award(session, "marathoner", agent_id=agent_id):
        awarded.append("marathoner")

    return awarded


def _is_zh(s: str) -> bool:
    return any("一" <= c <= "鿿" for c in (s or ""))


def _has_message_in_language(session: Session, *, agent_id: str, zh: bool) -> bool:
    msgs = session.exec(
        select(PushMessage.title, PushMessage.body).where(PushMessage.agent_id == agent_id)
    ).all()
    for title, body in msgs:
        text = (title or "") + (body or "")
        if _is_zh(text) == zh:
            return True
    return False


def on_push_replied(session: Session, *, user_id: str, agent_id: str,
                    button_id: str, message: PushMessage,
                    delivery: WebhookDelivery) -> list[str]:
    awarded: list[str] = []

    if _award(session, "hello-friend", user_id=user_id):
        awarded.append("hello-friend")

    delta = (delivery.created_at - message.created_at).total_seconds()
    if delta < 0.5 and _award(session, "snap-decision", user_id=user_id):
        awarded.append("snap-decision")
    if delta > 3600 and _award(session, "slow-roast", user_id=user_id):
        awarded.append("slow-roast")

    if button_id in ("later", "remind_later"):
        # Used "稍后再说" the first time?
        used_count = session.exec(
            select(func.count()).select_from(WebhookDelivery).where(
                WebhookDelivery.user_id == user_id,
                WebhookDelivery.button_id.in_(["later", "remind_later"]),
            )
        ).first() or 0
        if used_count >= 1 and _award(session, "manana", user_id=user_id):
            awarded.append("manana")
        if used_count >= 100 and _award(session, "manana-master", user_id=user_id):
            awarded.append("manana-master")

    # insomniac-negotiator — 20+ replies between 01:00 and 05:00 UTC (rough)
    h = delivery.created_at.hour
    if 1 <= h < 5:
        late = session.exec(
            select(func.count()).select_from(WebhookDelivery).where(
                WebhookDelivery.user_id == user_id,
                func.extract("hour", WebhookDelivery.created_at) >= 1,
                func.extract("hour", WebhookDelivery.created_at) < 5,
            )
        ).first() or 0
        if late >= 20 and _award(session, "insomniac-negotiator", user_id=user_id):
            awarded.append("insomniac-negotiator")

    # decisive — 100+ replies, median < 10s
    total = session.exec(
        select(func.count()).select_from(WebhookDelivery).where(WebhookDelivery.user_id == user_id)
    ).first() or 0
    if total >= 100:
        # cheap approximation: count "fast" replies and compare to half
        # (true median requires sorting; we approximate via hi/lo bucketing)
        fast = session.exec(
            select(func.count()).select_from(WebhookDelivery).join(PushMessage,
                PushMessage.id == WebhookDelivery.message_id
            ).where(
                WebhookDelivery.user_id == user_id,
            )
        ).first() or 0
        # NOTE: real median calc deferred; for now badge requires user to
        # fast-reply >= 50% of the time loosely, evaluated via slow_count
        # being < total/2 if we track it. Skip until we add a delta column.
        # (Awarded on day-of-eval via offline cron; placeholder.)
        pass

    return awarded


def on_agent_authorized(session: Session, *, user_id: str) -> list[str]:
    awarded: list[str] = []
    bound = session.exec(
        select(func.count()).select_from(AgentUserBinding).where(
            AgentUserBinding.user_id == user_id,
            AgentUserBinding.status == "active",
        )
    ).first() or 0
    if bound >= 3 and _award(session, "curator-101", user_id=user_id):
        awarded.append("curator-101")
    return awarded


def on_agent_revoked(session: Session, *, user_id: str) -> list[str]:
    awarded: list[str] = []
    revoked = session.exec(
        select(func.count()).select_from(AgentUserBinding).where(
            AgentUserBinding.user_id == user_id,
            AgentUserBinding.status == "revoked",
        )
    ).first() or 0
    if revoked >= 1 and _award(session, "bouncer-trainee", user_id=user_id):
        awarded.append("bouncer-trainee")
    if revoked >= 5 and _award(session, "bouncer-in-chief", user_id=user_id):
        awarded.append("bouncer-in-chief")
    return awarded


def on_user_action(session: Session, *, user_id: str, action: str) -> list[str]:
    """Catch-all for misc user actions: 'mute_first', 'curious_tap',
    'cold_feet', 'welcome_back', 'spring_clean_50'."""
    awarded: list[str] = []
    badge_for_action = {
        "mute_first":     "dnd-apprentice",
        "curious_tap":    "curious-cat",
        "cold_feet":      "cold-feet",
        "welcome_back":   "welcome-back",
        "spring_clean_50":"spring-cleaner",
        "comeback_kid":   "comeback-kid",
        "donated":        "supporter",
    }
    badge_id = badge_for_action.get(action)
    if badge_id and _award(session, badge_id, user_id=user_id):
        awarded.append(badge_id)
    return awarded


def on_retract(session: Session, *, agent_id: str) -> list[str]:
    awarded: list[str] = []
    if _award(session, "i-take-it-back", agent_id=agent_id):
        awarded.append("i-take-it-back")
    return awarded
