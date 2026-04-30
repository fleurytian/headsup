"""Endpoints called by the iOS app."""
import asyncio
import json
import secrets
from datetime import datetime, timedelta
from typing import Optional

from fastapi import APIRouter, BackgroundTasks, Depends, Header, HTTPException
from sqlmodel import Session, select

import json
from database import get_session
from models import (
    ActionReportRequest,
    Agent,
    AgentPublicResponse,
    AgentUserBinding,
    AppCategoryResponse,
    AppleSignInRequest,
    AppleSignInResponse,
    AppUser,
    AuthConfirmRequest,
    AuthorizationRequest,
    Category,
    CategoryButton,
    DeviceRegisterRequest,
    DeviceRegisterResponse,
    HistoryEntry,
    MuteRequest,
    PushMessage,
    WebhookDelivery,
)
from services import event_bus, badges as badges_svc, events
from services.agent_branding import resolve_accent
from services.apple_signin import verify_identity_token
from services.webhook import deliver_webhook
from models import Badge as BadgeRow, EarnedBadge


def get_authed_user(
    authorization: str = Header(default=""),
    session: Session = Depends(get_session),
) -> AppUser:
    """Validate Bearer token and return the AppUser."""
    if not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token")
    token = authorization.split(" ", 1)[1].strip()
    user = session.exec(select(AppUser).where(AppUser.session_token == token)).first()
    if not user:
        raise HTTPException(status_code=401, detail="Invalid session token")
    return user

router = APIRouter(prefix="/app", tags=["app"])

BUTTON_LABELS = {
    "confirm": "确认", "reject": "拒绝",
    "yes": "是", "no": "否",
    "approve": "批准", "cancel": "取消",
    "option_a": "选项 A", "option_b": "选项 B",
    "agree": "同意", "decline": "婉拒",
    "remind_later": "稍后提醒", "skip": "跳过",
    "action": "执行", "dismiss": "忽略",
    "helpful": "有帮助", "not_helpful": "无帮助",
    "later": "稍后再说",  # auto-appended to every category that has < 4 buttons
}


@router.post("/sign-in-apple", response_model=AppleSignInResponse)
async def sign_in_apple(req: AppleSignInRequest, session: Session = Depends(get_session)):
    """Verifies an Apple Sign In identity token and returns a session token.

    Accepts an optional `nonce` (the raw client-side string the iOS app
    used as `ASAuthorizationAppleIDRequest.nonce`'s SHA-256 hex digest).
    When supplied, the server recomputes the digest and matches it to the
    token's `nonce` claim — so an intercepted identity_token can't be
    replayed by a third party that doesn't know the original nonce.
    Older clients that don't send a nonce still work for backward compat
    until we cut a release that requires it.
    """
    try:
        claims = await verify_identity_token(
            req.identity_token, raw_nonce=req.nonce
        )
    except ValueError as e:
        raise HTTPException(status_code=401, detail=f"Invalid Apple token: {e}")

    apple_user_id = claims["sub"]
    email = claims.get("email") or req.email

    user = session.exec(
        select(AppUser).where(AppUser.apple_user_id == apple_user_id)
    ).first()

    if not user:
        user = AppUser(
            apple_user_id=apple_user_id,
            email=email,
            full_name=req.full_name,
            apns_device_token=req.apns_device_token,
            session_token=secrets.token_urlsafe(32),
        )
        session.add(user)
    else:
        if email and not user.email:
            user.email = email
        if req.full_name and not user.full_name:
            user.full_name = req.full_name
        if req.apns_device_token:
            user.apns_device_token = req.apns_device_token
        if not user.session_token:
            user.session_token = secrets.token_urlsafe(32)

    session.commit()
    session.refresh(user)
    return AppleSignInResponse(
        user_key=user.user_key,
        session_token=user.session_token,
        apple_user_id=apple_user_id,
    )


@router.post("/register-device", response_model=DeviceRegisterResponse)
def register_device(
    req: DeviceRegisterRequest,
    user: AppUser = Depends(get_authed_user),
    session: Session = Depends(get_session),
):
    """Updates the APNs device token for the authenticated user."""
    user.apns_device_token = req.apns_device_token
    session.add(user)
    session.commit()
    return DeviceRegisterResponse(user_key=user.user_key)


@router.post("/authorize/confirm")
def confirm_authorization(
    req: AuthConfirmRequest,
    background_tasks: BackgroundTasks,
    user: AppUser = Depends(get_authed_user),
    session: Session = Depends(get_session),
):
    """Called from iOS app after user taps Authorize on the web consent page.
    user_key in the request body must match the authed user."""
    if req.user_key != user.user_key:
        raise HTTPException(status_code=403, detail="user_key does not match session")

    auth_req = session.exec(
        select(AuthorizationRequest).where(
            AuthorizationRequest.token == req.token,
            AuthorizationRequest.used == False,
        )
    ).first()

    if not auth_req:
        raise HTTPException(status_code=404, detail="Authorization link is invalid (already used or never existed)")
    if auth_req.expires_at < datetime.utcnow():
        raise HTTPException(status_code=410, detail="Authorization link expired — ask the agent to send a fresh one")

    existing = session.exec(
        select(AgentUserBinding).where(
            AgentUserBinding.agent_id == auth_req.agent_id,
            AgentUserBinding.user_id == user.id,
        )
    ).first()

    if existing:
        existing.status = "active"
        session.add(existing)
    else:
        binding = AgentUserBinding(agent_id=auth_req.agent_id, user_id=user.id)
        session.add(binding)

    auth_req.used = True
    auth_req.user_id = user.id
    session.add(auth_req)
    session.commit()

    try:
        awarded = badges_svc.on_agent_authorized(session, user_id=user.id)
        if awarded:
            background_tasks.add_task(badges_svc.celebrate_async, awarded, user_id=user.id)
    except Exception:
        pass

    events.safe_log(
        session,
        kind="agent_authorized",
        actor_kind="user",
        actor_id=user.id,
        meta={"agent_id": auth_req.agent_id},
    )

    return {"status": "bound", "agent_id": auth_req.agent_id}


@router.post("/actions/report")
async def report_action(
    req: ActionReportRequest,
    background_tasks: BackgroundTasks,
    user: AppUser = Depends(get_authed_user),
    session: Session = Depends(get_session),
):
    """Called by iOS app when user taps a notification button.
    The message must belong to the authed user."""
    message = session.get(PushMessage, req.message_id)
    if not message:
        raise HTTPException(status_code=404, detail="Message not found")
    if message.user_id != user.id:
        raise HTTPException(status_code=403, detail="Message does not belong to this user")

    # Prefer the label iOS sent us (it knows what the user actually saw on the button).
    # Only fall back to BUTTON_LABELS for the 8 built-in categories.
    if req.button_label:
        label = req.button_label
    elif message.category_id in {"confirm_reject", "yes_no", "approve_cancel", "choose_a_b",
                                  "agree_decline", "remind_later_skip", "action_dismiss", "feedback"}:
        label = BUTTON_LABELS.get(req.button_id, req.button_id)
    else:
        label = req.button_id

    delivery = WebhookDelivery(
        message_id=message.id,
        agent_id=message.agent_id,
        user_id=user.id,
        user_key=user.user_key,
        button_id=req.button_id,
        button_label=label,
        category_id=message.category_id,
        data=message.data,
    )
    session.add(delivery)
    session.commit()
    session.refresh(delivery)

    background_tasks.add_task(deliver_webhook, delivery.id)

    # Badges (best-effort; never break delivery on a badge eval bug).
    try:
        awarded = badges_svc.on_push_replied(
            session, user_id=user.id, agent_id=message.agent_id,
            button_id=req.button_id, message=message, delivery=delivery,
        )
        if awarded:
            background_tasks.add_task(badges_svc.celebrate_async, awarded, user_id=user.id)
    except Exception:
        pass

    events.safe_log(
        session,
        kind="push_replied",
        actor_kind="user",
        actor_id=user.id,
        meta={
            "message_id": message.id,
            "agent_id": message.agent_id,
            "button_id": req.button_id,
            "category_id": message.category_id,
        },
    )

    # Parse `data` once before publishing — webhook + /v1/responses both
    # surface it as a dict, so SSE must too. Was a string before and broke
    # consumers that switched between transports.
    parsed_data = {}
    if message.data:
        try:
            parsed_data = json.loads(message.data)
        except (json.JSONDecodeError, TypeError):
            parsed_data = {}

    # Notify any open SSE streams for this agent — replaces the polling tax.
    await event_bus.publish(message.agent_id, {
        "message_id": delivery.message_id,
        "user_key": user.user_key,
        "agent_id": message.agent_id,
        "button_id": delivery.button_id,
        "button_label": delivery.button_label,
        "category_id": message.category_id,
        "data": parsed_data,
        "replied_at": delivery.created_at.isoformat(),
    })

    return {"status": "received"}


@router.get("/bindings")
def get_bindings(
    user: AppUser = Depends(get_authed_user),
    session: Session = Depends(get_session),
):
    """Returns all active agent bindings for the authed user."""
    from models import Agent
    bindings = session.exec(
        select(AgentUserBinding).where(
            AgentUserBinding.user_id == user.id,
            AgentUserBinding.status == "active",
        )
    ).all()

    result = []
    for b in bindings:
        agent = session.get(Agent, b.agent_id)
        if not agent:
            continue
        # Latest push timestamp lets the agent list sort by recency and
        # show "active 3m ago" tags without an extra round trip per row.
        latest = session.exec(
            select(PushMessage)
            .where(PushMessage.agent_id == agent.id, PushMessage.user_id == user.id)
            .order_by(PushMessage.created_at.desc())
            .limit(1)
        ).first()
        # Unread = pushes with buttons (not info_only) that have no
        # WebhookDelivery row yet — i.e. user hasn't tapped any button.
        # `outerjoin` would be cleaner but SQLModel + simple select keeps it
        # readable; the # of pushes per agent×user is small.
        agent_messages = session.exec(
            select(PushMessage).where(
                PushMessage.agent_id == agent.id,
                PushMessage.user_id == user.id,
                PushMessage.category_id != "info_only",
            )
        ).all()
        unread = 0
        for m in agent_messages:
            answered = session.exec(
                select(WebhookDelivery).where(WebhookDelivery.message_id == m.id).limit(1)
            ).first()
            if not answered:
                unread += 1
        result.append({
            "agent_id":         agent.id,
            "agent_name":       agent.name,
            "agent_logo_url":   agent.logo_url,
            "agent_accent_color": resolve_accent(agent),
            "agent_description": agent.description,
            "agent_type":       agent.agent_type,
            "bound_at":         b.bound_at,
            "mute_until":       b.mute_until,
            "last_message_at":  latest.created_at if latest else None,
            "last_message_title": latest.title if latest else None,
            "unread_count":     unread,
        })
    # Most recently active agents first, fall back to bind order.
    result.sort(key=lambda r: r.get("last_message_at") or r["bound_at"], reverse=True)
    return result


@router.post("/bindings/{agent_id}/defer-all-unread")
async def defer_all_unread(
    agent_id: str,
    background_tasks: BackgroundTasks,
    user: AppUser = Depends(get_authed_user),
    session: Session = Depends(get_session),
):
    """Reply 'later' (稍后再说) to every unanswered push from this agent.

    Used by the iOS 'one-click clear unread' button. Each reply still goes
    through the full webhook/SSE delivery path so the agent sees them as
    individual `button_id=later` events — no special bulk webhook shape.
    Idempotent on the user's side: messages already replied to are skipped.
    """
    binding = session.exec(
        select(AgentUserBinding).where(
            AgentUserBinding.user_id == user.id,
            AgentUserBinding.agent_id == agent_id,
            AgentUserBinding.status == "active",
        )
    ).first()
    if not binding:
        raise HTTPException(404, "Binding not found")

    messages = session.exec(
        select(PushMessage).where(
            PushMessage.agent_id == agent_id,
            PushMessage.user_id == user.id,
            PushMessage.category_id != "info_only",
        )
    ).all()
    deferred = 0
    for m in messages:
        already = session.exec(
            select(WebhookDelivery).where(WebhookDelivery.message_id == m.id).limit(1)
        ).first()
        if already:
            continue
        delivery = WebhookDelivery(
            message_id=m.id,
            agent_id=agent_id,
            user_id=user.id,
            user_key=user.user_key,
            button_id="later",
            button_label="稍后再说",
            category_id=m.category_id,
            data=m.data,
        )
        session.add(delivery)
        session.commit()
        session.refresh(delivery)
        background_tasks.add_task(deliver_webhook, delivery.id)
        parsed_data = {}
        if m.data:
            try:
                parsed_data = json.loads(m.data)
            except (json.JSONDecodeError, TypeError):
                parsed_data = {}
        await event_bus.publish(agent_id, {
            "message_id": delivery.message_id,
            "user_key": user.user_key,
            "agent_id": agent_id,
            "button_id": "later",
            "button_label": "稍后再说",
            "category_id": m.category_id,
            "data": parsed_data,
            "replied_at": delivery.created_at.isoformat(),
        })
        deferred += 1
    return {"deferred": deferred}


@router.post("/bindings/{agent_id}/mute")
def mute_binding(
    agent_id: str,
    req: MuteRequest,
    user: AppUser = Depends(get_authed_user),
    session: Session = Depends(get_session),
):
    """Silence one specific agent for N minutes (or unmute).

    Distinct from POST /mute, which silences the whole app for the user.
    Per-binding mute lets the user keep getting pushes from agents they
    care about while shutting up a chatty one.
    """
    binding = session.exec(
        select(AgentUserBinding).where(
            AgentUserBinding.user_id == user.id,
            AgentUserBinding.agent_id == agent_id,
            AgentUserBinding.status == "active",
        )
    ).first()
    if not binding:
        raise HTTPException(404, "Binding not found")

    if req.minutes is None or req.minutes <= 0:
        binding.mute_until = None
    else:
        binding.mute_until = datetime.utcnow() + timedelta(minutes=req.minutes)
    session.add(binding)
    session.commit()

    events.safe_log(
        session,
        kind="agent_muted_per_binding" if binding.mute_until else "agent_unmuted_per_binding",
        actor_kind="user",
        actor_id=user.id,
        meta={"agent_id": agent_id, "minutes": req.minutes},
    )
    return {"agent_id": agent_id, "mute_until": binding.mute_until}


@router.post("/bindings/{agent_id}/mark-all-read")
def mark_all_read(
    agent_id: str,
    user: AppUser = Depends(get_authed_user),
    session: Session = Depends(get_session),
):
    """Silent 'mark as read' for every unanswered push from this agent.

    Distinct from /defer-all-unread: this does NOT fire a webhook to the agent
    — it's purely a local cleanup so the user's unread badge clears without
    spamming the agent with N×'later' replies for stale prompts they no longer
    care about.

    Implementation: insert WebhookDelivery rows with button_id="_read" and
    status="suppressed" so the unread query (which counts messages without
    a delivery row) returns zero, but the webhook worker skips them.
    """
    binding = session.exec(
        select(AgentUserBinding).where(
            AgentUserBinding.user_id == user.id,
            AgentUserBinding.agent_id == agent_id,
            AgentUserBinding.status == "active",
        )
    ).first()
    if not binding:
        raise HTTPException(404, "Binding not found")

    messages = session.exec(
        select(PushMessage).where(
            PushMessage.agent_id == agent_id,
            PushMessage.user_id == user.id,
            PushMessage.category_id != "info_only",
        )
    ).all()
    marked = 0
    for m in messages:
        already = session.exec(
            select(WebhookDelivery).where(WebhookDelivery.message_id == m.id).limit(1)
        ).first()
        if already:
            continue
        delivery = WebhookDelivery(
            message_id=m.id,
            agent_id=agent_id,
            user_id=user.id,
            user_key=user.user_key,
            button_id="_read",
            button_label="已读",
            category_id=m.category_id,
            data=m.data,
            status="suppressed",
        )
        session.add(delivery)
        marked += 1
    session.commit()
    events.safe_log(
        session, kind="bulk_marked_read",
        actor_kind="user", actor_id=user.id,
        meta={"agent_id": agent_id, "count": marked},
    )
    return {"marked": marked}


@router.get("/bindings/{agent_id}/badges")
def agent_badges_for_user(
    agent_id: str,
    user: AppUser = Depends(get_authed_user),
    session: Session = Depends(get_session),
):
    """Badges earned by one of the user's authorized agents.

    This is user-facing, not the agent-authenticated `/v1/agents/me/badges`.
    It only returns badges for an active binding the user owns.
    """
    binding = session.exec(
        select(AgentUserBinding).where(
            AgentUserBinding.user_id == user.id,
            AgentUserBinding.agent_id == agent_id,
            AgentUserBinding.status == "active",
        )
    ).first()
    if not binding:
        raise HTTPException(404, "Binding not found")

    earned_rows = session.exec(
        select(EarnedBadge).where(EarnedBadge.agent_id == agent_id)
    ).all()
    earned = {e.badge_id: e for e in earned_rows}
    badges = session.exec(
        select(BadgeRow).where(BadgeRow.scope.in_(["agent", "pair"]))
    ).all()

    out = []
    for b in badges:
        e = earned.get(b.id)
        # User-facing agent badges should be a trophy shelf, not a full
        # checklist. Hide unearned secret badges and omit unearned rows from
        # the strip in the iOS detail page.
        if not e:
            continue
        out.append({
            "id": b.id,
            "scope": b.scope,
            "name_zh": b.name_zh, "name_en": b.name_en,
            "description_zh": b.description_zh, "description_en": b.description_en,
            "criterion_zh": b.criterion_zh or "",
            "criterion_en": b.criterion_en or "",
            "icon": b.icon,
            "secret": b.secret,
            "early": b.early,
            "earned_at": e.earned_at.isoformat(),
        })
    return {"badges": out, "earned_count": len(out), "total_visible": len(out)}


@router.delete("/bindings/{agent_id}", status_code=204)
def revoke_binding(
    agent_id: str,
    background_tasks: BackgroundTasks,
    user: AppUser = Depends(get_authed_user),
    session: Session = Depends(get_session),
):
    """Authed user revokes an agent's access."""
    binding = session.exec(
        select(AgentUserBinding).where(
            AgentUserBinding.user_id == user.id,
            AgentUserBinding.agent_id == agent_id,
            AgentUserBinding.status == "active",
        )
    ).first()
    if not binding:
        raise HTTPException(status_code=404, detail="Binding not found")

    binding.status = "revoked"
    session.add(binding)
    session.commit()

    try:
        awarded = badges_svc.on_agent_revoked(session, user_id=user.id)
        if awarded:
            background_tasks.add_task(badges_svc.celebrate_async, awarded, user_id=user.id)
    except Exception:
        pass

    events.safe_log(
        session,
        kind="agent_revoked",
        actor_kind="user",
        actor_id=user.id,
        meta={"agent_id": agent_id},
    )


@router.get("/categories", response_model=list[AppCategoryResponse])
def list_categories_for_app(
    user: AppUser = Depends(get_authed_user),
    session: Session = Depends(get_session),
):
    """All categories from agents this user is currently bound to. iOS App registers them."""
    bindings = session.exec(
        select(AgentUserBinding).where(
            AgentUserBinding.user_id == user.id,
            AgentUserBinding.status == "active",
        )
    ).all()
    agent_ids = [b.agent_id for b in bindings]
    if not agent_ids:
        return []

    cats = session.exec(
        select(Category).where(Category.agent_id.in_(agent_ids))
    ).all()

    return [
        AppCategoryResponse(
            ios_id=c.ios_id,
            buttons=[CategoryButton(**b) for b in json.loads(c.buttons)],
        )
        for c in cats
    ]


# ── Public agent profile (used by web /authorize page + iOS preview) ─────────

@router.get("/public/agents/{agent_id}", response_model=AgentPublicResponse)
def public_agent_info(agent_id: str, session: Session = Depends(get_session)):
    agent = session.get(Agent, agent_id)
    if not agent:
        raise HTTPException(status_code=404, detail="Agent not found")
    return AgentPublicResponse(
        id=agent.id,
        name=agent.name,
        description=agent.description,
        logo_url=agent.logo_url,
        accent_color=resolve_accent(agent),
        agent_type=agent.agent_type,
        created_at=agent.created_at,
    )


@router.get("/public/auth-requests/{token}")
def public_auth_request(token: str, session: Session = Depends(get_session)):
    """Resolve an authorization token to its agent + status.
    Used by the iOS app to render the consent screen given only `token`
    in the deep link — so URLs no longer need to carry agent_id and
    can't be mangled by agents who shorten or drop query params.
    """
    auth_req = session.exec(
        select(AuthorizationRequest).where(
            AuthorizationRequest.token == token,
        )
    ).first()
    if not auth_req:
        raise HTTPException(status_code=404,
            detail="Authorization link is invalid (already used or never existed)")
    if auth_req.expires_at < datetime.utcnow():
        raise HTTPException(status_code=410,
            detail="Authorization link expired — ask the agent to send a fresh one")
    if auth_req.used:
        raise HTTPException(status_code=409,
            detail="Authorization link already used")
    agent = session.get(Agent, auth_req.agent_id)
    if not agent:
        raise HTTPException(status_code=404, detail="Agent not found")
    return {
        "token": token,
        "agent": AgentPublicResponse(
            id=agent.id,
            name=agent.name,
            description=agent.description,
            logo_url=agent.logo_url,
            accent_color=resolve_accent(agent),
            agent_type=agent.agent_type,
            created_at=agent.created_at,
        ),
        "expires_at": auth_req.expires_at.isoformat(),
    }


# ── DND / mute ───────────────────────────────────────────────────────────────

@router.post("/mute")
def set_mute(
    req: MuteRequest,
    background_tasks: BackgroundTasks,
    user: AppUser = Depends(get_authed_user),
    session: Session = Depends(get_session),
):
    if req.minutes is None or req.minutes <= 0:
        user.mute_until = None
    else:
        user.mute_until = datetime.utcnow() + timedelta(minutes=req.minutes)
    session.add(user)
    session.commit()

    if req.minutes and req.minutes > 0:
        try:
            awarded = badges_svc.on_user_action(session, user_id=user.id, action="mute_first")
            if awarded:
                background_tasks.add_task(badges_svc.celebrate_async, awarded, user_id=user.id)
        except Exception:
            pass

    events.safe_log(
        session,
        kind="agent_muted" if req.minutes and req.minutes > 0 else "agent_unmuted",
        actor_kind="user",
        actor_id=user.id,
        meta={"minutes": req.minutes},
    )

    return {"mute_until": user.mute_until}


@router.get("/me")
def me(user: AppUser = Depends(get_authed_user)):
    return {
        "user_key": user.user_key,
        "email": user.email,
        "full_name": user.full_name,
        "mute_until": user.mute_until,
        "has_device_token": bool(user.apns_device_token),
    }


@router.delete("/me", status_code=204)
def delete_me(
    user: AppUser = Depends(get_authed_user),
    session: Session = Depends(get_session),
):
    """Permanently delete the user and all their data.

    App Store guideline 5.1.1(v) — apps that let people create accounts must let
    people delete them. Cascades:
      - all bindings (so agents can no longer push to this user)
      - all push messages and webhook deliveries (history wiped)
      - the user row itself
    The user can later sign in with the same Apple ID and start fresh.
    """
    user_id = user.id
    # 1. webhook deliveries
    for d in session.exec(
        select(WebhookDelivery).where(WebhookDelivery.user_key == user.user_key)
    ).all():
        session.delete(d)
    # 2. push messages
    for m in session.exec(
        select(PushMessage).where(PushMessage.user_id == user_id)
    ).all():
        session.delete(m)
    # 3. bindings
    for b in session.exec(
        select(AgentUserBinding).where(AgentUserBinding.user_id == user_id)
    ).all():
        session.delete(b)
    # 4. user
    session.delete(user)
    session.commit()


# ── Per-user push history ────────────────────────────────────────────────────

@router.get("/history", response_model=list[HistoryEntry])
def my_history(
    user: AppUser = Depends(get_authed_user),
    session: Session = Depends(get_session),
    agent_id: Optional[str] = None,
    limit: int = 50,
):
    """Push history of this user, optionally filtered by agent."""
    q = select(PushMessage).where(PushMessage.user_id == user.id)
    if agent_id:
        q = q.where(PushMessage.agent_id == agent_id)
    msgs = session.exec(
        q.order_by(PushMessage.created_at.desc()).limit(min(limit, 200))
    ).all()

    out = []
    for m in msgs:
        agent = session.get(Agent, m.agent_id)
        # Fetch latest delivery for this message (user's button click)
        delivery = session.exec(
            select(WebhookDelivery).where(WebhookDelivery.message_id == m.id)
            .order_by(WebhookDelivery.created_at.desc())
        ).first()
        out.append(HistoryEntry(
            message_id=m.id,
            agent_id=m.agent_id,
            agent_name=agent.name if agent else "?",
            agent_logo_url=agent.logo_url if agent else None,
            agent_accent_color=resolve_accent(agent) if agent else None,
            title=m.title,
            body=m.body,
            category_id=m.category_id,
            sent_at=m.created_at,
            button_id=delivery.button_id if delivery else None,
            button_label=delivery.button_label if delivery else None,
            responded_at=delivery.created_at if delivery else None,
        ))
    return out


# ── Stats / data / badges / diagnose ─────────────────────────────────────────

@router.get("/me/stats")
def my_stats(user: AppUser = Depends(get_authed_user), session: Session = Depends(get_session)):
    """Today's-summary numbers for the home screen header.

    Cheap, no agent breakdown — that's what /me/data is for.
    """
    from sqlalchemy import func as _func
    today_start = datetime.utcnow().replace(hour=0, minute=0, second=0, microsecond=0)
    received_today = session.exec(
        select(_func.count()).select_from(PushMessage).where(
            PushMessage.user_id == user.id,
            PushMessage.created_at >= today_start,
        )
    ).first() or 0
    replied_today = session.exec(
        select(_func.count()).select_from(WebhookDelivery).where(
            WebhookDelivery.user_id == user.id,
            WebhookDelivery.created_at >= today_start,
        )
    ).first() or 0
    # Unanswered across all agents (excluding info_only)
    pending = session.exec(
        select(PushMessage).where(
            PushMessage.user_id == user.id,
            PushMessage.category_id != "info_only",
        )
    ).all()
    unread_total = sum(
        1 for m in pending
        if not session.exec(select(WebhookDelivery).where(WebhookDelivery.message_id == m.id).limit(1)).first()
    )
    return {
        "received_today": received_today,
        "replied_today": replied_today,
        "unread_total": unread_total,
    }


@router.get("/me/data")
def my_data(user: AppUser = Depends(get_authed_user), session: Session = Depends(get_session)):
    """Lifetime stats — for Settings → My Data.

    Heatmap-style hourly breakdown is computed on the fly. Acceptable up
    to a few thousand messages; switch to a materialized view if it gets slow.
    """
    from sqlalchemy import func as _func
    total_received = session.exec(
        select(_func.count()).select_from(PushMessage).where(PushMessage.user_id == user.id)
    ).first() or 0
    total_replied = session.exec(
        select(_func.count()).select_from(WebhookDelivery).where(WebhookDelivery.user_id == user.id)
    ).first() or 0
    deliveries = session.exec(
        select(WebhookDelivery, PushMessage).where(
            WebhookDelivery.user_id == user.id,
            PushMessage.id == WebhookDelivery.message_id,
        )
    ).all()
    deltas = []
    hour_buckets = [0] * 24
    for d, m in deliveries:
        if m and d:
            delta = (d.created_at - m.created_at).total_seconds()
            if 0 <= delta <= 7 * 24 * 3600:
                deltas.append(delta)
            hour_buckets[d.created_at.hour] += 1
    deltas.sort()
    median = deltas[len(deltas) // 2] if deltas else None
    response_rate = (total_replied / total_received) if total_received else None
    return {
        "total_received": total_received,
        "total_replied": total_replied,
        "response_rate": response_rate,
        "median_response_seconds": median,
        "hour_histogram": hour_buckets,
        "since": user.created_at if hasattr(user, "created_at") else None,
    }


@router.get("/me/badges")
def my_badges(user: AppUser = Depends(get_authed_user), session: Session = Depends(get_session)):
    """All user-scope + paired badges, with `earned_at` set when held."""
    earned = {
        e.badge_id: e for e in session.exec(
            select(EarnedBadge).where(EarnedBadge.user_id == user.id)
        ).all()
    }
    out = []
    rows = session.exec(select(BadgeRow).where(BadgeRow.scope.in_(["user", "pair"]))).all()
    for b in rows:
        e = earned.get(b.id)
        # Hide secret + unearned from the locked list — only the earned ones
        # should reveal a secret badge's existence.
        if b.secret and not e:
            continue
        out.append({
            "id": b.id,
            "scope": b.scope,
            "name_zh": b.name_zh, "name_en": b.name_en,
            "description_zh": b.description_zh, "description_en": b.description_en,
            "criterion_zh": b.criterion_zh or "",
            "criterion_en": b.criterion_en or "",
            "icon": b.icon,
            "secret": b.secret,
            "early": b.early,
            "earned_at": e.earned_at.isoformat() if e else None,
        })
    return {"badges": out, "earned_count": len(earned), "total_visible": len(out)}


@router.post("/me/badges/curious-tap", status_code=204)
def curious_tap(
    background_tasks: BackgroundTasks,
    user: AppUser = Depends(get_authed_user),
    session: Session = Depends(get_session),
):
    """Trigger the meta 'Curious Cat' badge — the only one that earns by being
    looked at. iOS calls this when the user taps a locked badge."""
    try:
        awarded = badges_svc.on_user_action(session, user_id=user.id, action="curious_tap")
        if awarded:
            background_tasks.add_task(badges_svc.celebrate_async, awarded, user_id=user.id)
    except Exception:
        pass


@router.post("/me/cold-feet", status_code=204)
def cold_feet(
    background_tasks: BackgroundTasks,
    user: AppUser = Depends(get_authed_user),
    session: Session = Depends(get_session),
):
    """User opened the Delete Account dialog and chose Cancel."""
    try:
        awarded = badges_svc.on_user_action(session, user_id=user.id, action="cold_feet")
        if awarded:
            background_tasks.add_task(badges_svc.celebrate_async, awarded, user_id=user.id)
    except Exception:
        pass
    events.safe_log(
        session, kind="delete_account_canceled",
        actor_kind="user", actor_id=user.id,
    )


@router.post("/me/claim-supporter", status_code=204)
def claim_supporter(
    background_tasks: BackgroundTasks,
    user: AppUser = Depends(get_authed_user),
    session: Session = Depends(get_session),
):
    """Trust-based 'I donated' claim for the Supporter badge.

    No verification — GitHub Sponsors doesn't (cheaply) tell us who
    a given AppUser is. The badge ego-rewards real donors and trusts
    everyone else won't go through the trouble for a 💝 they could
    just look at in the catalog.

    Idempotent: re-claiming on an already-supporter user does nothing
    via _award's existing-record check.
    """
    try:
        awarded = badges_svc.on_user_action(session, user_id=user.id, action="donated")
        if awarded:
            background_tasks.add_task(badges_svc.celebrate_async, awarded, user_id=user.id)
    except Exception:
        pass
    events.safe_log(
        session, kind="supporter_claimed",
        actor_kind="user", actor_id=user.id,
    )


@router.post("/me/ping", status_code=204)
def app_opened_ping(
    user: AppUser = Depends(get_authed_user),
    session: Session = Depends(get_session),
):
    """Lightweight beacon iOS sends on app foreground / cold start.
    Used to compute DAU/MAU and "did we lose them" cohorts."""
    events.safe_log(
        session, kind="app_opened",
        actor_kind="user", actor_id=user.id,
    )


@router.post("/me/demo-push", status_code=202)
async def demo_push(
    background_tasks: BackgroundTasks,
    user: AppUser = Depends(get_authed_user),
    session: Session = Depends(get_session),
):
    """Reviewer-friendly self-test: ensures a 'HeadsUp Demo' agent exists,
    binds it to the caller if not already bound, and fires one push the
    user can long-press to test the reply flow.

    Doubles as a smoke test for end-users — Settings has a 'Test
    notification' button that hits this. No API key plumbing required;
    the user is already authenticated.

    Push is `confirm_reject` so the reviewer sees a real two-button reply
    dialog (the most representative case of HeadsUp's value prop).
    """
    from auth import hash_password
    DEMO_EMAIL = "demo@headsup.md"

    # 1. Make sure the Demo agent exists. Idempotent — first call creates,
    #    subsequent calls reuse the same row.
    demo_agent = session.exec(select(Agent).where(Agent.email == DEMO_EMAIL)).first()
    if not demo_agent:
        demo_agent = Agent(
            name="HeadsUp Demo",
            email=DEMO_EMAIL,
            password_hash=hash_password(secrets.token_urlsafe(32)),
            description=(
                "A built-in agent that sends one test notification when "
                "you tap 'Test notification' in Settings."
            ),
            agent_type="assistant",
            accent_color="#6B60A8",
            webhook_url=None,
        )
        session.add(demo_agent)
        session.commit()
        session.refresh(demo_agent)

    # 2. Make sure user is bound to the Demo agent.
    binding = session.exec(
        select(AgentUserBinding).where(
            AgentUserBinding.agent_id == demo_agent.id,
            AgentUserBinding.user_id == user.id,
        )
    ).first()
    if not binding:
        binding = AgentUserBinding(agent_id=demo_agent.id, user_id=user.id)
        session.add(binding)
        session.commit()
    elif binding.status == "revoked":
        binding.status = "active"
        binding.mute_until = None
        session.add(binding)
        session.commit()

    # 3. Send one push to the user. Reuse the regular push pipeline so
    #    the reviewer's experience is identical to a real agent's push.
    if not user.apns_device_token:
        raise HTTPException(
            400,
            {"code": "USER_NO_DEVICE",
             "message": "No APNs device token registered. Allow notifications first."},
        )
    message = PushMessage(
        agent_id=demo_agent.id,
        user_id=user.id,
        title="Test notification",
        body=(
            "This is the HeadsUp demo. Long-press this banner to see the "
            "reply buttons, then tap one — your response goes back to the "
            "Demo agent within a second."
        ),
        category_id="confirm_reject",
        ttl=600,
    )
    session.add(message)
    session.commit()
    session.refresh(message)
    # Defer to the same background sender used by /v1/push.
    from routers.push import _send_and_update
    background_tasks.add_task(_send_and_update, message.id, user.apns_device_token)

    events.safe_log(
        session, kind="demo_push_sent",
        actor_kind="user", actor_id=user.id,
        meta={"agent_id": demo_agent.id, "message_id": message.id},
    )
    return {
        "status": "queued",
        "message_id": message.id,
        "agent_id": demo_agent.id,
        "agent_name": demo_agent.name,
    }


@router.get("/me/diagnose")
def diagnose(user: AppUser = Depends(get_authed_user), session: Session = Depends(get_session)):
    """Self-test the user's setup — surfaces 'why am I not getting pushes?'."""
    bindings = session.exec(
        select(AgentUserBinding).where(
            AgentUserBinding.user_id == user.id,
            AgentUserBinding.status == "active",
        )
    ).all()
    return {
        "user_key": user.user_key,
        "has_apns_token": bool(user.apns_device_token),
        "muted_until": user.mute_until,
        "active_bindings": len(bindings),
        "session_ok": True,                     # we only got here if session was valid
        "server_time": datetime.utcnow().isoformat(),
    }
