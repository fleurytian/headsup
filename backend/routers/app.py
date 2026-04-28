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
        raise HTTPException(status_code=400, detail="Invalid or expired token")
    if auth_req.expires_at < datetime.utcnow():
        raise HTTPException(status_code=400, detail="Token expired")

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
        if agent:
            result.append({"agent_id": agent.id, "agent_name": agent.name, "bound_at": b.bound_at})
    return result


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
        created_at=agent.created_at,
    )


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
