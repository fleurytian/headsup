from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session, select

from database import get_session
from deps import get_current_agent
from models import Agent, AgentUserBinding, AppUser, UserBindingResponse

router = APIRouter(prefix="/users", tags=["users"])


@router.get("", response_model=list[UserBindingResponse])
def list_users(
    agent: Agent = Depends(get_current_agent),
    session: Session = Depends(get_session),
    page: int = 1,
    page_size: int = 20,
):
    offset = (page - 1) * page_size
    bindings = session.exec(
        select(AgentUserBinding)
        .where(AgentUserBinding.agent_id == agent.id, AgentUserBinding.status == "active")
        .offset(offset)
        .limit(page_size)
    ).all()

    results = []
    for b in bindings:
        user = session.get(AppUser, b.user_id)
        if user:
            results.append(
                UserBindingResponse(
                    user_key=user.user_key,
                    status=b.status,
                    bound_at=b.bound_at,
                )
            )
    return results


@router.delete("/{user_key}", status_code=204)
def unbind_user(
    user_key: str,
    agent: Agent = Depends(get_current_agent),
    session: Session = Depends(get_session),
):
    user = session.exec(select(AppUser).where(AppUser.user_key == user_key)).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    binding = session.exec(
        select(AgentUserBinding).where(
            AgentUserBinding.agent_id == agent.id,
            AgentUserBinding.user_id == user.id,
            AgentUserBinding.status == "active",
        )
    ).first()
    if not binding:
        raise HTTPException(status_code=404, detail="Binding not found")

    binding.status = "revoked"
    session.add(binding)
    session.commit()
