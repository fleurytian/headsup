"""Agent-facing CRUD for custom notification categories."""
import json
import re
from datetime import datetime

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from sqlmodel import Session, select

from database import engine, get_session
from deps import get_current_agent
from models import (
    Agent,
    AgentUserBinding,
    AppUser,
    Category,
    CategoryButton,
    CategoryCreateRequest,
    CategoryResponse,
)
from services.apns import send_silent_push

router = APIRouter(prefix="/categories", tags=["categories"])

NAME_RE = re.compile(r"^[a-z][a-z0-9_]{1,31}$")
RESERVED_NAMES = {
    "confirm_reject", "yes_no", "approve_cancel", "choose_a_b",
    "agree_decline", "remind_later_skip", "action_dismiss", "feedback",
}


def _ios_id(agent_id: str, name: str) -> str:
    return f"a{agent_id.replace('-', '')[:12]}_{name}"


def _to_response(c: Category) -> CategoryResponse:
    return CategoryResponse(
        id=c.id,
        name=c.name,
        ios_id=c.ios_id,
        buttons=[CategoryButton(**b) for b in json.loads(c.buttons)],
        created_at=c.created_at,
        updated_at=c.updated_at,
    )


def _validate_buttons(buttons: list[CategoryButton]) -> None:
    if not 1 <= len(buttons) <= 4:
        raise HTTPException(status_code=400, detail="Categories must have 1–4 buttons")
    for b in buttons:
        if not 1 <= len(b.label) <= 20:
            raise HTTPException(status_code=400, detail=f"Button label '{b.label}' too long")
        if not re.match(r"^[a-z][a-z0-9_]*$", b.id):
            raise HTTPException(status_code=400, detail=f"Button id '{b.id}' must be lowercase snake_case")
    ids = [b.id for b in buttons]
    if len(set(ids)) != len(ids):
        raise HTTPException(status_code=400, detail="Button ids must be unique")


async def _notify_users_of_category_change(agent_id: str) -> None:
    """Send a silent push to every active bound user so iOS App refreshes categories."""
    with Session(engine) as session:
        bindings = session.exec(
            select(AgentUserBinding).where(
                AgentUserBinding.agent_id == agent_id,
                AgentUserBinding.status == "active",
            )
        ).all()
        device_tokens = []
        for b in bindings:
            user = session.get(AppUser, b.user_id)
            if user and user.apns_device_token:
                device_tokens.append(user.apns_device_token)

    for token in device_tokens:
        await send_silent_push(token, {"type": "categories_updated"})


@router.post("", response_model=CategoryResponse, status_code=201)
def create_category(
    req: CategoryCreateRequest,
    background_tasks: BackgroundTasks,
    agent: Agent = Depends(get_current_agent),
    session: Session = Depends(get_session),
):
    if not NAME_RE.match(req.name):
        raise HTTPException(
            status_code=400,
            detail="Name must be lowercase snake_case, 2–32 chars, e.g. 'pay_or_wait'",
        )
    if req.name in RESERVED_NAMES:
        raise HTTPException(status_code=400, detail=f"'{req.name}' is a built-in category name")

    existing = session.exec(
        select(Category).where(
            Category.agent_id == agent.id, Category.name == req.name
        )
    ).first()
    if existing:
        raise HTTPException(status_code=400, detail="Category with this name already exists")

    _validate_buttons(req.buttons)

    cat = Category(
        agent_id=agent.id,
        name=req.name,
        ios_id=_ios_id(agent.id, req.name),
        buttons=json.dumps([b.model_dump() for b in req.buttons]),
    )
    session.add(cat)
    session.commit()
    session.refresh(cat)

    background_tasks.add_task(_notify_users_of_category_change, agent.id)
    return _to_response(cat)


@router.get("", response_model=list[CategoryResponse])
def list_categories(
    agent: Agent = Depends(get_current_agent),
    session: Session = Depends(get_session),
):
    cats = session.exec(
        select(Category).where(Category.agent_id == agent.id).order_by(Category.created_at.desc())
    ).all()
    return [_to_response(c) for c in cats]


@router.patch("/{name}", response_model=CategoryResponse)
def update_category(
    name: str,
    req: CategoryCreateRequest,
    background_tasks: BackgroundTasks,
    agent: Agent = Depends(get_current_agent),
    session: Session = Depends(get_session),
):
    cat = session.exec(
        select(Category).where(Category.agent_id == agent.id, Category.name == name)
    ).first()
    if not cat:
        raise HTTPException(status_code=404, detail="Category not found")

    _validate_buttons(req.buttons)
    cat.buttons = json.dumps([b.model_dump() for b in req.buttons])
    cat.updated_at = datetime.utcnow()
    session.add(cat)
    session.commit()
    session.refresh(cat)

    background_tasks.add_task(_notify_users_of_category_change, agent.id)
    return _to_response(cat)


@router.delete("/{name}", status_code=204)
def delete_category(
    name: str,
    background_tasks: BackgroundTasks,
    agent: Agent = Depends(get_current_agent),
    session: Session = Depends(get_session),
):
    cat = session.exec(
        select(Category).where(Category.agent_id == agent.id, Category.name == name)
    ).first()
    if not cat:
        raise HTTPException(status_code=404, detail="Category not found")
    session.delete(cat)
    session.commit()
    background_tasks.add_task(_notify_users_of_category_change, agent.id)
