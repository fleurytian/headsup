from datetime import datetime, timedelta
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, status
from sqlmodel import Session, select

from auth import create_access_token, hash_password, verify_password
from config import settings
from database import get_session
from deps import get_current_agent
from models import (
    Agent,
    AgentLoginRequest,
    AgentRegisterRequest,
    AgentResponse,
    AuthorizationRequest,
    Badge as BadgeRow,
    EarnedBadge,
    gen_api_key,
)

AUTH_TOKEN_TTL_MINUTES = 30

router = APIRouter(prefix="/agents", tags=["agents"])


@router.post("/register", response_model=AgentResponse, status_code=201)
def register(req: AgentRegisterRequest, session: Session = Depends(get_session)):
    existing = session.exec(select(Agent).where(Agent.email == req.email)).first()
    if existing:
        raise HTTPException(status_code=400, detail="Email already registered")

    from models import AGENT_TYPES
    if req.agent_type and req.agent_type not in AGENT_TYPES:
        raise HTTPException(
            status_code=400,
            detail=f"agent_type must be one of: {', '.join(AGENT_TYPES.keys())}",
        )

    agent = Agent(
        name=req.name,
        email=req.email,
        password_hash=hash_password(req.password),
        webhook_url=req.webhook_url,
        description=req.description,
        logo_url=req.logo_url,
        agent_type=req.agent_type,
        accent_color=req.accent_color,
    )
    session.add(agent)
    session.commit()
    session.refresh(agent)
    return agent


@router.post("/login")
def login(req: AgentLoginRequest, session: Session = Depends(get_session)):
    agent = session.exec(select(Agent).where(Agent.email == req.email)).first()
    if not agent or not verify_password(req.password, agent.password_hash):
        raise HTTPException(status_code=401, detail="Invalid credentials")

    return {
        "access_token": create_access_token(agent.id),
        "token_type": "bearer",
        "api_key": agent.api_key,
        "agent_id": agent.id,
    }


@router.get("/me", response_model=AgentResponse)
def me(agent: Agent = Depends(get_current_agent)):
    return agent


@router.patch("/me")
def update_me(
    webhook_url: Optional[str] = None,
    accent_color: Optional[str] = None,
    logo_url: Optional[str] = None,
    description: Optional[str] = None,
    session: Session = Depends(get_session),
    agent: Agent = Depends(get_current_agent),
):
    changed = False
    if webhook_url is not None:
        agent.webhook_url = webhook_url
        changed = True
    if accent_color is not None:
        # Empty string clears it; otherwise must look like a hex color.
        if accent_color == "":
            agent.accent_color = None
        else:
            ac = accent_color.strip()
            if not ac.startswith("#") or len(ac) not in (4, 7):
                raise HTTPException(400, "accent_color must be hex like #6B60A8")
            agent.accent_color = ac
        changed = True
    if logo_url is not None:
        agent.logo_url = logo_url or None
        changed = True
    if description is not None:
        agent.description = description or None
        changed = True
    if changed:
        session.add(agent)
        session.commit()
    return {
        "webhook_url": agent.webhook_url,
        "accent_color": agent.accent_color,
        "logo_url": agent.logo_url,
        "description": agent.description,
    }


@router.post("/regenerate-key", response_model=AgentResponse)
def regenerate_key(
    session: Session = Depends(get_session),
    agent: Agent = Depends(get_current_agent),
):
    agent.api_key = gen_api_key()
    session.add(agent)
    session.commit()
    session.refresh(agent)
    return agent


@router.post("/auth-links", status_code=201)
def create_auth_link(
    session: Session = Depends(get_session),
    agent: Agent = Depends(get_current_agent),
):
    """JSON-native onboarding helper for agents.

    Returns the deep link, the public web URL, and the raw token in one
    JSON payload — agents don't have to scrape the HTML page returned by
    /authorize/initiate, parse out the deep link, or guess the URL shape.

    Pattern (from skill.md):
        bot.create_auth_link() -> {"auth_url": "...", ...}
        send to user
        poll GET /v1/users until binding appears, OR receive webhook

    Token expires in 30 minutes. Single-use. Multiple in-flight tokens
    per agent are fine — each one is independent.
    """
    auth_req = AuthorizationRequest(
        agent_id=agent.id,
        expires_at=datetime.utcnow() + timedelta(minutes=AUTH_TOKEN_TTL_MINUTES),
    )
    session.add(auth_req)
    session.commit()
    session.refresh(auth_req)
    base = settings.base_url.rstrip("/")
    return {
        "token":      auth_req.token,
        "deep_link":  f"headsup://authorize?token={auth_req.token}",
        "auth_url":   f"{base}/authorize?token={auth_req.token}",
        "expires_at": auth_req.expires_at.isoformat() + "Z",
        "ttl_seconds": AUTH_TOKEN_TTL_MINUTES * 60,
    }


@router.get("/auth-links/{token}")
def get_auth_link_status(
    token: str,
    session: Session = Depends(get_session),
    agent: Agent = Depends(get_current_agent),
):
    """Check whether a previously-issued auth link has been used.

    Returns:
      { "status": "pending" | "bound" | "expired" | "invalid",
        "user_key": "uk_..." }      ← only when status == "bound"

    Lets agents poll instead of standing up a webhook for the auth flow.
    """
    auth_req = session.exec(
        select(AuthorizationRequest).where(
            AuthorizationRequest.token == token,
            AuthorizationRequest.agent_id == agent.id,
        )
    ).first()
    if not auth_req:
        return {"status": "invalid"}
    if auth_req.expires_at < datetime.utcnow() and not auth_req.used:
        return {"status": "expired"}
    if not auth_req.used or not auth_req.user_id:
        return {"status": "pending"}
    from models import AppUser
    user = session.get(AppUser, auth_req.user_id)
    return {
        "status": "bound",
        "user_key": user.user_key if user else None,
    }


@router.get("/me/badges")
def my_badges(
    session: Session = Depends(get_session),
    agent: Agent = Depends(get_current_agent),
):
    """The agent's own earned-badge log. Lets agents (or their CLIs) brag.

    Excludes secret badges the agent hasn't earned yet — they're meant to
    surprise. Earned secret badges DO appear, with `secret: true` so a UI
    can render them differently.
    """
    earned = session.exec(
        select(EarnedBadge).where(EarnedBadge.agent_id == agent.id)
    ).all()
    earned_ids = {e.badge_id: e for e in earned}

    visible_rows = session.exec(
        select(BadgeRow).where(BadgeRow.scope.in_(["agent", "pair"]))
    ).all()

    out = []
    for b in visible_rows:
        e = earned_ids.get(b.id)
        if b.secret and not e:
            continue
        out.append({
            "id": b.id,
            "name_zh": b.name_zh,
            "name_en": b.name_en,
            "description_zh": b.description_zh,
            "description_en": b.description_en,
            "icon": b.icon,
            "scope": b.scope,
            "secret": b.secret,
            "earned": e is not None,
            "earned_at": e.earned_at.isoformat() if e else None,
        })
    return {
        "badges": out,
        "earned_count": sum(1 for r in out if r["earned"]),
        "total_visible": len(out),
    }
