"""Web UI: Agent Dashboard + User Authorization flow."""
from datetime import datetime, timedelta

from typing import Optional
from fastapi import APIRouter, BackgroundTasks, Depends, Form, HTTPException, Request, Response
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from sqlmodel import Session, select

from auth import create_access_token, hash_password, verify_password
from config import settings
from database import get_session
from models import (
    Agent,
    AgentUserBinding,
    AppUser,
    AuthorizationRequest,
    PushMessage,
    gen_auth_token,
)

router = APIRouter(tags=["web"])
templates = Jinja2Templates(directory="templates")

AUTH_TOKEN_TTL_MINUTES = 30


# ── Authorization flow ────────────────────────────────────────────────────────

@router.get("/authorize", response_class=HTMLResponse)
def authorize_page(
    request: Request,
    token: Optional[str] = None,
    agent_id: Optional[str] = None,
    session: Session = Depends(get_session),
):
    """Renders the in-Safari "Open in HeadsUp" landing.

    Accepts either:
      - ?token=<t>            ← preferred. agent_id is looked up from the token.
      - ?token=<t>&agent_id=  ← legacy form, still works.
      - ?agent_id=<id>        ← legacy form for static permanent links.
    """
    agent = None
    deep_link_token = token
    if token:
        auth_req = session.exec(
            select(AuthorizationRequest).where(AuthorizationRequest.token == token)
        ).first()
        if auth_req:
            agent = session.get(Agent, auth_req.agent_id)
    if not agent and agent_id:
        agent = session.get(Agent, agent_id)
    if not agent:
        return HTMLResponse("<h1>Agent not found</h1>", status_code=404)

    return templates.TemplateResponse("authorize.html", {
        "request": request,
        "agent": agent,
        "token": deep_link_token,
        "base_url": settings.base_url,
    })


@router.post("/authorize/initiate")
def authorize_initiate(
    request: Request,
    agent_id: str = Form(...),
    session: Session = Depends(get_session),
):
    """Creates a short-lived token and redirects to the iOS app via deep link."""
    agent = session.get(Agent, agent_id)
    if not agent:
        raise HTTPException(status_code=404, detail="Agent not found")

    auth_req = AuthorizationRequest(
        agent_id=agent_id,
        expires_at=datetime.utcnow() + timedelta(minutes=AUTH_TOKEN_TTL_MINUTES),
    )
    session.add(auth_req)
    session.commit()

    # Token-only deep link — the iOS app looks up agent_id from the token
    # (via /v1/app/public/auth-requests/<token>). Half the URL length, half
    # the chance of an agent dropping a query param.
    deep_link = f"headsup://authorize?token={auth_req.token}"
    app_store_url = "https://apps.apple.com/app/headsup"
    return templates.TemplateResponse("authorize_redirect.html", {
        "request": request,
        "deep_link": deep_link,
        "app_store_url": app_store_url,
        "agent_name": agent.name,
    })


# ── Dashboard ─────────────────────────────────────────────────────────────────

def _get_dashboard_agent(request: Request, session: Session) -> Optional[Agent]:
    token = request.cookies.get("dashboard_token")
    if not token:
        return None
    from auth import decode_access_token
    agent_id = decode_access_token(token)
    if not agent_id:
        return None
    return session.get(Agent, agent_id)


@router.get("/dashboard/login", response_class=HTMLResponse)
def dashboard_login(request: Request):
    return templates.TemplateResponse("dashboard/login.html", {"request": request, "error": None})


@router.post("/dashboard/login", response_class=HTMLResponse)
def dashboard_login_post(
    request: Request,
    email: str = Form(...),
    password: str = Form(...),
    session: Session = Depends(get_session),
):
    agent = session.exec(select(Agent).where(Agent.email == email)).first()
    if not agent or not verify_password(password, agent.password_hash):
        return templates.TemplateResponse(
            "dashboard/login.html", {"request": request, "error": "Invalid email or password"}
        )
    token = create_access_token(agent.id)
    resp = RedirectResponse("/dashboard", status_code=303)
    resp.set_cookie("dashboard_token", token, httponly=True, max_age=60 * 60 * 24 * 30)
    return resp


@router.get("/dashboard/register", response_class=HTMLResponse)
def dashboard_register(request: Request):
    return templates.TemplateResponse("dashboard/register.html", {"request": request, "error": None})


@router.post("/dashboard/register", response_class=HTMLResponse)
def dashboard_register_post(
    request: Request,
    name: str = Form(...),
    email: str = Form(...),
    password: str = Form(...),
    webhook_url: str = Form(default=""),
    session: Session = Depends(get_session),
):
    existing = session.exec(select(Agent).where(Agent.email == email)).first()
    if existing:
        return templates.TemplateResponse(
            "dashboard/register.html", {"request": request, "error": "Email already registered"}
        )
    agent = Agent(
        name=name,
        email=email,
        password_hash=hash_password(password),
        webhook_url=webhook_url or None,
    )
    session.add(agent)
    session.commit()
    token = create_access_token(agent.id)
    resp = RedirectResponse("/dashboard", status_code=303)
    resp.set_cookie("dashboard_token", token, httponly=True, max_age=60 * 60 * 24 * 30)
    return resp


@router.get("/dashboard", response_class=HTMLResponse)
def dashboard_home(request: Request, session: Session = Depends(get_session)):
    agent = _get_dashboard_agent(request, session)
    if not agent:
        return RedirectResponse("/dashboard/login")

    user_count = len(session.exec(
        select(AgentUserBinding).where(
            AgentUserBinding.agent_id == agent.id,
            AgentUserBinding.status == "active",
        )
    ).all())

    recent_messages = session.exec(
        select(PushMessage)
        .where(PushMessage.agent_id == agent.id)
        .order_by(PushMessage.created_at.desc())
        .limit(5)
    ).all()

    return templates.TemplateResponse("dashboard/index.html", {
        "request": request,
        "agent": agent,
        "user_count": user_count,
        "recent_messages": recent_messages,
        "auth_link": f"{settings.base_url}/authorize?agent_id={agent.id}",
    })


@router.get("/dashboard/users", response_class=HTMLResponse)
def dashboard_users(request: Request, session: Session = Depends(get_session)):
    agent = _get_dashboard_agent(request, session)
    if not agent:
        return RedirectResponse("/dashboard/login")

    bindings = session.exec(
        select(AgentUserBinding).where(
            AgentUserBinding.agent_id == agent.id,
            AgentUserBinding.status == "active",
        ).order_by(AgentUserBinding.bound_at.desc())
    ).all()

    users = []
    for b in bindings:
        user = session.get(AppUser, b.user_id)
        if user:
            users.append({"user_key": user.user_key, "bound_at": b.bound_at})

    return templates.TemplateResponse("dashboard/users.html", {
        "request": request,
        "agent": agent,
        "users": users,
    })


@router.get("/dashboard/messages", response_class=HTMLResponse)
def dashboard_messages(request: Request, session: Session = Depends(get_session)):
    agent = _get_dashboard_agent(request, session)
    if not agent:
        return RedirectResponse("/dashboard/login")

    messages = session.exec(
        select(PushMessage)
        .where(PushMessage.agent_id == agent.id)
        .order_by(PushMessage.created_at.desc())
        .limit(50)
    ).all()

    enriched = []
    for m in messages:
        user = session.get(AppUser, m.user_id)
        enriched.append({
            "id": m.id,
            "user_key": user.user_key if user else "?",
            "title": m.title,
            "body": m.body,
            "category_id": m.category_id,
            "status": m.status,
            "created_at": m.created_at,
        })

    return templates.TemplateResponse("dashboard/messages.html", {
        "request": request,
        "agent": agent,
        "messages": enriched,
    })


@router.get("/dashboard/settings", response_class=HTMLResponse)
def dashboard_settings(request: Request, session: Session = Depends(get_session)):
    agent = _get_dashboard_agent(request, session)
    if not agent:
        return RedirectResponse("/dashboard/login")
    return templates.TemplateResponse("dashboard/settings.html", {
        "request": request,
        "agent": agent,
        "auth_link": f"{settings.base_url}/authorize?agent_id={agent.id}",
    })


@router.post("/dashboard/settings", response_class=HTMLResponse)
def dashboard_settings_post(
    request: Request,
    webhook_url: str = Form(default=""),
    description: str = Form(default=""),
    logo_url: str = Form(default=""),
    session: Session = Depends(get_session),
):
    agent = _get_dashboard_agent(request, session)
    if not agent:
        return RedirectResponse("/dashboard/login")
    agent.webhook_url = webhook_url or None
    agent.description = description or None
    agent.logo_url = logo_url or None
    session.add(agent)
    session.commit()
    return templates.TemplateResponse("dashboard/settings.html", {
        "request": request,
        "agent": agent,
        "auth_link": f"{settings.base_url}/authorize?agent_id={agent.id}",
        "saved": True,
    })


@router.post("/dashboard/logout")
def dashboard_logout():
    resp = RedirectResponse("/dashboard/login", status_code=303)
    resp.delete_cookie("dashboard_token")
    return resp


# ── Custom categories management ─────────────────────────────────────────────

@router.get("/dashboard/categories", response_class=HTMLResponse)
def dashboard_categories(request: Request, session: Session = Depends(get_session)):
    agent = _get_dashboard_agent(request, session)
    if not agent:
        return RedirectResponse("/dashboard/login")
    from models import Category
    import json as _json
    cats_raw = session.exec(
        select(Category).where(Category.agent_id == agent.id).order_by(Category.created_at.desc())
    ).all()
    cats = [
        {
            "name": c.name,
            "ios_id": c.ios_id,
            "buttons": _json.loads(c.buttons),
        }
        for c in cats_raw
    ]
    return templates.TemplateResponse("dashboard/categories.html", {
        "request": request,
        "agent": agent,
        "categories": cats,
    })


@router.post("/dashboard/categories", response_class=HTMLResponse)
async def dashboard_categories_post(request: Request, background_tasks: BackgroundTasks, session: Session = Depends(get_session)):
    agent = _get_dashboard_agent(request, session)
    if not agent:
        return RedirectResponse("/dashboard/login")

    from routers.categories import _ios_id, _validate_buttons, NAME_RE, RESERVED_NAMES, _notify_users_of_category_change
    from models import Category, CategoryButton
    import json as _json

    form = await request.form()
    name = (form.get("name") or "").strip()
    buttons: list[CategoryButton] = []
    for i in range(4):
        bid = form.get(f"btn_id_{i}")
        if not bid:
            continue
        buttons.append(CategoryButton(
            id=bid.strip(),
            label=(form.get(f"btn_label_{i}") or "").strip(),
            icon=(form.get(f"btn_icon_{i}") or "").strip() or None,
            destructive=form.get(f"btn_destructive_{i}") in ("on", "true", "1"),
        ))

    error = None
    saved = None
    try:
        if not NAME_RE.match(name):
            raise HTTPException(status_code=400, detail="Name must be lowercase snake_case 2–32 chars")
        if name in RESERVED_NAMES:
            raise HTTPException(status_code=400, detail=f"'{name}' is built-in")
        existing = session.exec(
            select(Category).where(Category.agent_id == agent.id, Category.name == name)
        ).first()
        if existing:
            raise HTTPException(status_code=400, detail="Category with that name already exists")
        _validate_buttons(buttons)
        cat = Category(
            agent_id=agent.id, name=name, ios_id=_ios_id(agent.id, name),
            buttons=_json.dumps([b.model_dump() for b in buttons]),
        )
        session.add(cat); session.commit()
        background_tasks.add_task(_notify_users_of_category_change, agent.id)
        saved = f"Created '{name}'. Pushing the new template to your users' phones."
    except HTTPException as e:
        error = e.detail if isinstance(e.detail, str) else str(e.detail)

    cats_raw = session.exec(
        select(Category).where(Category.agent_id == agent.id).order_by(Category.created_at.desc())
    ).all()
    return templates.TemplateResponse("dashboard/categories.html", {
        "request": request, "agent": agent,
        "categories": [{"name": c.name, "ios_id": c.ios_id, "buttons": _json.loads(c.buttons)} for c in cats_raw],
        "saved": saved, "error": error,
    })


@router.get("/dashboard/debug", response_class=HTMLResponse)
def dashboard_debug(request: Request, session: Session = Depends(get_session)):
    agent = _get_dashboard_agent(request, session)
    if not agent:
        return RedirectResponse("/dashboard/login")
    return templates.TemplateResponse("dashboard/debug.html", {
        "request": request, "agent": agent,
    })


@router.post("/dashboard/categories/{name}/delete")
def dashboard_categories_delete(name: str, request: Request, session: Session = Depends(get_session)):
    agent = _get_dashboard_agent(request, session)
    if not agent:
        return RedirectResponse("/dashboard/login")
    from models import Category
    cat = session.exec(
        select(Category).where(Category.agent_id == agent.id, Category.name == name)
    ).first()
    if cat:
        session.delete(cat); session.commit()
    return RedirectResponse("/dashboard/categories", status_code=303)
