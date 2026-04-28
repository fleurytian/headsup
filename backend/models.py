import secrets
from datetime import datetime
from typing import Optional
from sqlmodel import Field, SQLModel, Relationship
import uuid


def gen_uuid() -> str:
    return str(uuid.uuid4())


def gen_api_key() -> str:
    return "pk_" + secrets.token_urlsafe(32)


def gen_user_key() -> str:
    return "uk_" + secrets.token_urlsafe(16)


def gen_auth_token() -> str:
    return secrets.token_urlsafe(32)


# ── Database Models ──────────────────────────────────────────────────────────

class Agent(SQLModel, table=True):
    id: str = Field(default_factory=gen_uuid, primary_key=True)
    name: str
    email: str = Field(unique=True, index=True)
    password_hash: str
    api_key: str = Field(default_factory=gen_api_key, unique=True, index=True)
    webhook_url: Optional[str] = None
    description: Optional[str] = None     # shown to users on authorize page
    logo_url: Optional[str] = None        # optional avatar URL
    created_at: datetime = Field(default_factory=datetime.utcnow)

    bindings: list["AgentUserBinding"] = Relationship(back_populates="agent")
    messages: list["PushMessage"] = Relationship(back_populates="agent")


class AppUser(SQLModel, table=True):
    id: str = Field(default_factory=gen_uuid, primary_key=True)
    user_key: str = Field(default_factory=gen_user_key, unique=True, index=True)
    apns_device_token: Optional[str] = None
    email: Optional[str] = None
    apple_user_id: Optional[str] = Field(default=None, unique=True, index=True)
    full_name: Optional[str] = None
    session_token: Optional[str] = Field(default=None, unique=True, index=True)
    mute_until: Optional[datetime] = None   # if set + future, pushes are dropped (DND)
    created_at: datetime = Field(default_factory=datetime.utcnow)

    bindings: list["AgentUserBinding"] = Relationship(back_populates="user")


class AgentUserBinding(SQLModel, table=True):
    id: str = Field(default_factory=gen_uuid, primary_key=True)
    agent_id: str = Field(foreign_key="agent.id", index=True)
    user_id: str = Field(foreign_key="appuser.id", index=True)
    status: str = Field(default="active")  # active | revoked
    bound_at: datetime = Field(default_factory=datetime.utcnow)

    agent: Optional[Agent] = Relationship(back_populates="bindings")
    user: Optional[AppUser] = Relationship(back_populates="bindings")


class PushMessage(SQLModel, table=True):
    id: str = Field(default_factory=gen_uuid, primary_key=True)
    external_id: Optional[str] = None  # agent-provided message_id
    agent_id: str = Field(foreign_key="agent.id", index=True)
    user_id: str = Field(foreign_key="appuser.id", index=True)
    title: str
    body: str
    subtitle: Optional[str] = None
    image_url: Optional[str] = None
    category_id: str
    data: Optional[str] = None  # JSON string
    status: str = Field(default="queued")  # queued | delivered | failed
    ttl: int = Field(default=3600)
    created_at: datetime = Field(default_factory=datetime.utcnow)
    delivered_at: Optional[datetime] = None

    agent: Optional[Agent] = Relationship(back_populates="messages")


class WebhookDelivery(SQLModel, table=True):
    id: str = Field(default_factory=gen_uuid, primary_key=True)
    message_id: str = Field(foreign_key="pushmessage.id", index=True)
    agent_id: str = Field(foreign_key="agent.id")
    user_id: str = Field(foreign_key="appuser.id")
    user_key: str  # denormalized for the webhook payload (agent-facing identifier)
    button_id: str
    button_label: str
    category_id: str
    data: Optional[str] = None  # JSON string — mirrors PushMessage.data
    status: str = Field(default="pending")  # pending | delivered | failed
    attempts: int = Field(default=0)
    next_retry_at: datetime = Field(default_factory=datetime.utcnow)
    created_at: datetime = Field(default_factory=datetime.utcnow)
    delivered_at: Optional[datetime] = None


class AuthorizationRequest(SQLModel, table=True):
    id: str = Field(default_factory=gen_uuid, primary_key=True)
    agent_id: str = Field(foreign_key="agent.id", index=True)
    token: str = Field(default_factory=gen_auth_token, unique=True, index=True)
    expires_at: datetime
    used: bool = Field(default=False)
    user_id: Optional[str] = Field(default=None, foreign_key="appuser.id")
    created_at: datetime = Field(default_factory=datetime.utcnow)


class Category(SQLModel, table=True):
    """Custom button-template defined by an Agent.

    The iOS App pulls these on launch and registers them with iOS.
    Agent pushes can reference category by `name` (Agent's local naming).
    The actual iOS identifier is `ios_id` to avoid cross-agent collisions.
    """
    id: str = Field(default_factory=gen_uuid, primary_key=True)
    agent_id: str = Field(foreign_key="agent.id", index=True)
    name: str = Field(index=True)        # agent-local name, e.g. "pay_or_wait"
    ios_id: str = Field(unique=True, index=True)  # globally unique on iOS
    buttons: str  # JSON: [{"id":"pay","label":"立即支付","icon":"checkmark.circle.fill"}, ...]
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)


# ── API Schemas (no table=True) ───────────────────────────────────────────────

class AgentRegisterRequest(SQLModel):
    name: str
    email: str
    password: str
    webhook_url: Optional[str] = None


class AgentLoginRequest(SQLModel):
    email: str
    password: str


class AgentResponse(SQLModel):
    id: str
    name: str
    email: str
    api_key: str
    webhook_url: Optional[str]
    created_at: datetime


class PushRequest(SQLModel):
    user_key: str
    category_id: str
    title: str
    body: str
    subtitle: Optional[str] = None      # iOS native middle-line text
    image_url: Optional[str] = None     # remote image, attached by NSE
    message_id: Optional[str] = None
    data: Optional[dict] = None
    ttl: int = 3600


class BroadcastRequest(SQLModel):
    user_keys: list[str]
    category_id: str
    title: str
    body: str
    subtitle: Optional[str] = None
    image_url: Optional[str] = None
    message_id: Optional[str] = None
    data: Optional[dict] = None
    ttl: int = 3600


class PushResponse(SQLModel):
    message_id: str
    status: str
    created_at: datetime


class UserBindingResponse(SQLModel):
    user_key: str
    status: str
    bound_at: datetime


class MessageResponse(SQLModel):
    id: str
    external_id: Optional[str]
    user_key: str
    title: str
    body: str
    category_id: str
    status: str
    created_at: datetime
    delivered_at: Optional[datetime]


class DeviceRegisterRequest(SQLModel):
    apns_device_token: str
    email: Optional[str] = None


class DeviceRegisterResponse(SQLModel):
    user_key: str


class ActionReportRequest(SQLModel):
    message_id: str
    button_id: str
    button_label: str


class AuthConfirmRequest(SQLModel):
    token: str
    user_key: str


class AppleSignInRequest(SQLModel):
    identity_token: str
    authorization_code: Optional[str] = None
    email: Optional[str] = None
    full_name: Optional[str] = None
    apns_device_token: Optional[str] = None


class AppleSignInResponse(SQLModel):
    user_key: str
    session_token: str
    apple_user_id: str


# ── Category schemas ─────────────────────────────────────────────────────────

class CategoryButton(SQLModel):
    id: str
    label: str
    icon: Optional[str] = None         # SF Symbol name OR emoji char
    destructive: bool = False


class CategoryCreateRequest(SQLModel):
    name: str
    buttons: list[CategoryButton]


class CategoryResponse(SQLModel):
    id: str
    name: str
    ios_id: str
    buttons: list[CategoryButton]
    created_at: datetime
    updated_at: datetime


class AppCategoryResponse(SQLModel):
    """Format consumed by the iOS app — minimal, registration-ready."""
    ios_id: str
    buttons: list[CategoryButton]


# ── Public agent info shown on authorize / app ────────────────────────────────

class AgentPublicResponse(SQLModel):
    id: str
    name: str
    description: Optional[str] = None
    logo_url: Optional[str] = None
    created_at: datetime


class MuteRequest(SQLModel):
    minutes: Optional[int] = None  # None = unmute; otherwise mute for N minutes


class HistoryEntry(SQLModel):
    message_id: str
    agent_id: str
    agent_name: str
    title: str
    body: str
    category_id: str
    sent_at: datetime
    button_id: Optional[str] = None
    button_label: Optional[str] = None
    responded_at: Optional[datetime] = None
