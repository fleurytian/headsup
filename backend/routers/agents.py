from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, status
from sqlmodel import Session, select

from auth import create_access_token, hash_password, verify_password
from database import get_session
from deps import get_current_agent
from models import (
    Agent,
    AgentLoginRequest,
    AgentRegisterRequest,
    AgentResponse,
    Badge as BadgeRow,
    EarnedBadge,
    gen_api_key,
)

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
