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
from services import event_bus
from services.apple_signin import verify_identity_token
from services.webhook import deliver_webhook


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
    """Verifies an Apple Sign In identity token and returns a session token."""
    try:
        claims = await verify_identity_token(req.identity_token)
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
            "agent_description": agent.description,
            "agent_type":       agent.agent_type,
            "bound_at":         b.bound_at,
            "last_message_at":  latest.created_at if latest else None,
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


@router.delete("/bindings/{agent_id}", status_code=204)
def revoke_binding(
    agent_id: str,
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
            agent_type=agent.agent_type,
            created_at=agent.created_at,
        ),
        "expires_at": auth_req.expires_at.isoformat(),
    }


# ── DND / mute ───────────────────────────────────────────────────────────────

@router.post("/mute")
def set_mute(
    req: MuteRequest,
    user: AppUser = Depends(get_authed_user),
    session: Session = Depends(get_session),
):
    if req.minutes is None or req.minutes <= 0:
        user.mute_until = None
    else:
        user.mute_until = datetime.utcnow() + timedelta(minutes=req.minutes)
    session.add(user)
    session.commit()
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
            title=m.title,
            body=m.body,
            category_id=m.category_id,
            sent_at=m.created_at,
            button_id=delivery.button_id if delivery else None,
            button_label=delivery.button_label if delivery else None,
            responded_at=delivery.created_at if delivery else None,
        ))
    return out
