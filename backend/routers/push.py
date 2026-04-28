import asyncio
import json
from datetime import datetime
from typing import Optional
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from sqlmodel import Session, select

from database import engine, get_session
from deps import get_current_agent
from models import (
    Agent,
    AgentUserBinding,
    AppUser,
    BroadcastRequest,
    Category,
    PushMessage,
    PushRequest,
    PushResponse,
    MessageResponse,
)
from services.apns import (
    send_push,
    MAX_TITLE_LEN,
    MAX_SUBTITLE_LEN,
    MAX_BODY_LEN,
    MAX_IMAGE_URL_LEN,
)
from services.webhook import deliver_webhook

router = APIRouter(tags=["push"])

BUILTIN_CATEGORIES = {
    "confirm_reject",
    "yes_no",
    "approve_cancel",
    "choose_a_b",
    "agree_decline",
    "remind_later_skip",
    "action_dismiss",
    "feedback",
}


def _validate_push_content(req) -> None:
    """Reject pushes whose title/body/etc. exceed iOS-friendly limits."""
    if len(req.title) > MAX_TITLE_LEN:
        raise HTTPException(
            status_code=400,
            detail={"code": "TITLE_TOO_LONG", "message": f"title must be ≤ {MAX_TITLE_LEN} chars"},
        )
    if len(req.body) > MAX_BODY_LEN:
        raise HTTPException(
            status_code=400,
            detail={"code": "BODY_TOO_LONG", "message": f"body must be ≤ {MAX_BODY_LEN} chars"},
        )
    if req.subtitle and len(req.subtitle) > MAX_SUBTITLE_LEN:
        raise HTTPException(
            status_code=400,
            detail={"code": "SUBTITLE_TOO_LONG", "message": f"subtitle must be ≤ {MAX_SUBTITLE_LEN} chars"},
        )
    if req.image_url:
        if len(req.image_url) > MAX_IMAGE_URL_LEN:
            raise HTTPException(
                status_code=400,
                detail={"code": "IMAGE_URL_TOO_LONG", "message": f"image_url must be ≤ {MAX_IMAGE_URL_LEN} chars"},
            )
        if not req.image_url.startswith(("http://", "https://")):
            raise HTTPException(
                status_code=400,
                detail={"code": "INVALID_IMAGE_URL", "message": "image_url must start with http(s)://"},
            )


def _resolve_category(category_id: str, agent_id: str, session: Session) -> str:
    """Returns the iOS-side identifier to put in the APNs payload.
    Built-ins map to themselves; custom names resolve to the agent's ios_id."""
    if category_id in BUILTIN_CATEGORIES:
        return category_id
    cat = session.exec(
        select(Category).where(Category.agent_id == agent_id, Category.name == category_id)
    ).first()
    if not cat:
        raise HTTPException(
            status_code=400,
            detail={
                "code": "INVALID_CATEGORY",
                "message": f"Category '{category_id}' is neither built-in nor defined by you",
            },
        )
    return cat.ios_id


def _get_active_user(user_key: str, agent_id: str, session: Session) -> AppUser:
    user = session.exec(select(AppUser).where(AppUser.user_key == user_key)).first()
    if not user:
        raise HTTPException(
            status_code=404,
            detail={
                "code": "USER_NOT_FOUND",
                "message": f"No user found with key {user_key}",
            },
        )
    binding = session.exec(
        select(AgentUserBinding).where(
            AgentUserBinding.agent_id == agent_id,
            AgentUserBinding.user_id == user.id,
            AgentUserBinding.status == "active",
        )
    ).first()
    if not binding:
        raise HTTPException(
            status_code=400,
            detail={
                "code": "USER_NOT_BOUND",
                "message": "This user has not authorized your agent",
                "solution": f"Share your agent authorization link with the user",
            },
        )
    if not user.apns_device_token:
        raise HTTPException(
            status_code=400,
            detail={
                "code": "USER_NO_DEVICE",
                "message": "User has not registered a device yet",
            },
        )
    if user.mute_until and user.mute_until > datetime.utcnow():
        raise HTTPException(
            status_code=429,
            detail={
                "code": "USER_MUTED",
                "message": f"User has muted notifications until {user.mute_until.isoformat()}",
            },
        )
    return user


async def _send_and_update(message_id: str, device_token: str):
    """Background task — opens its own DB session, never uses request-scoped one."""
    with Session(engine) as session:
        message = session.get(PushMessage, message_id)
        if not message:
            return
        ok, _reason = await send_push(
            device_token=device_token,
            title=message.title,
            body=message.body,
            category_id=message.category_id,
            message_id=message.id,
            data=json.loads(message.data) if message.data else None,
            ttl=message.ttl,
            subtitle=message.subtitle,
            image_url=message.image_url,
        )
        message.status = "delivered" if ok else "failed"
        if ok:
            message.delivered_at = datetime.utcnow()
        session.add(message)
        session.commit()


@router.post("/push", response_model=PushResponse, status_code=202)
async def push(
    req: PushRequest,
    background_tasks: BackgroundTasks,
    agent: Agent = Depends(get_current_agent),
    session: Session = Depends(get_session),
):
    _validate_push_content(req)
    ios_category = _resolve_category(req.category_id, agent.id, session)
    if not agent.webhook_url:
        raise HTTPException(
            status_code=400,
            detail={"code": "WEBHOOK_CONFIG_MISSING", "message": "Configure a webhook URL in your dashboard"},
        )

    user = _get_active_user(req.user_key, agent.id, session)

    message = PushMessage(
        external_id=req.message_id,
        agent_id=agent.id,
        user_id=user.id,
        title=req.title,
        body=req.body,
        subtitle=req.subtitle,
        image_url=req.image_url,
        category_id=ios_category,
        data=json.dumps(req.data) if req.data else None,
        ttl=req.ttl,
    )
    session.add(message)
    session.commit()
    session.refresh(message)

    background_tasks.add_task(_send_and_update, message.id, user.apns_device_token)

    return PushResponse(message_id=message.id, status="queued", created_at=message.created_at)


@router.post("/push/broadcast")
async def broadcast(
    req: BroadcastRequest,
    background_tasks: BackgroundTasks,
    agent: Agent = Depends(get_current_agent),
    session: Session = Depends(get_session),
):
    if len(req.user_keys) > 100:
        raise HTTPException(status_code=400, detail="Max 100 users per broadcast")
    _validate_push_content(req)
    ios_category = _resolve_category(req.category_id, agent.id, session)

    results = []
    for user_key in req.user_keys:
        try:
            user = _get_active_user(user_key, agent.id, session)
            message = PushMessage(
                external_id=req.message_id,
                agent_id=agent.id,
                user_id=user.id,
                title=req.title,
                body=req.body,
                subtitle=req.subtitle,
                image_url=req.image_url,
                category_id=ios_category,
                data=json.dumps(req.data) if req.data else None,
                ttl=req.ttl,
            )
            session.add(message)
            session.commit()
            session.refresh(message)
            background_tasks.add_task(_send_and_update, message.id, user.apns_device_token)
            results.append({"user_key": user_key, "status": "queued", "message_id": message.id})
        except HTTPException as e:
            results.append({"user_key": user_key, "status": "error", "detail": e.detail})

    return {"results": results, "total": len(results)}


@router.get("/messages", response_model=list[MessageResponse])
def list_messages(
    agent: Agent = Depends(get_current_agent),
    session: Session = Depends(get_session),
    page: int = 1,
    page_size: int = 20,
):
    offset = (page - 1) * page_size
    messages = session.exec(
        select(PushMessage)
        .where(PushMessage.agent_id == agent.id)
        .order_by(PushMessage.created_at.desc())
        .offset(offset)
        .limit(page_size)
    ).all()

    results = []
    for m in messages:
        user = session.get(AppUser, m.user_id)
        results.append(MessageResponse(
            id=m.id,
            external_id=m.external_id,
            user_key=user.user_key if user else "unknown",
            title=m.title,
            body=m.body,
            category_id=m.category_id,
            status=m.status,
            created_at=m.created_at,
            delivered_at=m.delivered_at,
        ))
    return results


@router.get("/responses")
def list_responses(
    agent: Agent = Depends(get_current_agent),
    session: Session = Depends(get_session),
    since: Optional[float] = None,           # unix timestamp
    message_id: Optional[str] = None,        # filter to one message
    limit: int = 50,
):
    """Poll for button-tap responses. Local agents use this when they can't host a webhook.

    `since` (unix ts) filters to deliveries newer than that time.
    `message_id` filters to one specific message.
    """
    from datetime import datetime as _dt
    from models import WebhookDelivery

    q = select(WebhookDelivery).where(WebhookDelivery.agent_id == agent.id)
    if since is not None:
        q = q.where(WebhookDelivery.created_at > _dt.utcfromtimestamp(since))
    if message_id is not None:
        q = q.where(WebhookDelivery.message_id == message_id)

    rows = session.exec(
        q.order_by(WebhookDelivery.created_at.desc()).limit(min(limit, 200))
    ).all()

    return [
        {
            "message_id": r.message_id,
            "user_key": r.user_key,
            "button_id": r.button_id,
            "button_label": r.button_label,
            "category_id": r.category_id,
            "data": json.loads(r.data) if r.data else {},
            "created_at": r.created_at.isoformat(),
        }
        for r in rows
    ]


@router.get("/messages/{message_id}", response_model=MessageResponse)
def get_message(
    message_id: str,
    agent: Agent = Depends(get_current_agent),
    session: Session = Depends(get_session),
):
    message = session.exec(
        select(PushMessage).where(
            PushMessage.id == message_id,
            PushMessage.agent_id == agent.id,
        )
    ).first()
    if not message:
        raise HTTPException(status_code=404, detail="Message not found")

    user = session.get(AppUser, message.user_id)
    return MessageResponse(
        id=message.id,
        external_id=message.external_id,
        user_key=user.user_key if user else "unknown",
        title=message.title,
        body=message.body,
        category_id=message.category_id,
        status=message.status,
        created_at=message.created_at,
        delivered_at=message.delivered_at,
    )
