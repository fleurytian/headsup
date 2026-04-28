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
    gen_api_key,
)

router = APIRouter(prefix="/agents", tags=["agents"])


@router.post("/register", response_model=AgentResponse, status_code=201)
def register(req: AgentRegisterRequest, session: Session = Depends(get_session)):
    existing = session.exec(select(Agent).where(Agent.email == req.email)).first()
    if existing:
        raise HTTPException(status_code=400, detail="Email already registered")

    agent = Agent(
        name=req.name,
        email=req.email,
        password_hash=hash_password(req.password),
        webhook_url=req.webhook_url,
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
    session: Session = Depends(get_session),
    agent: Agent = Depends(get_current_agent),
):
    if webhook_url is not None:
        agent.webhook_url = webhook_url
        session.add(agent)
        session.commit()
    return {"webhook_url": agent.webhook_url}


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
