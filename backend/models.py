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
    agent_type: Optional[str] = None      # slug: assistant | coding | automation | monitor | companion | research | other
    accent_color: Optional[str] = None    # hex like "#D97757" — used for avatar bg + tint everywhere
    created_at: datetime = Field(default_factory=datetime.utcnow)

    bindings: list["AgentUserBinding"] = Relationship(back_populates="agent")
    messages: list["PushMessage"] = Relationship(back_populates="agent")


AGENT_TYPES = {
    "assistant":  ("通用助手",   "General Assistant"),
    "coding":     ("代码助手",   "Coding"),
    "automation": ("自动化",     "Automation"),
    "monitor":    ("监控告警",   "Monitoring"),
    "companion":  ("生活伴侣",   "Companion"),
    "research":   ("研究分析",   "Research"),
    "other":      ("其他",       "Other"),
}


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
    level: Optional[str] = None
    sound: Optional[str] = None
    badge: Optional[int] = None
    group: Optional[str] = None
    url: Optional[str] = None
    auto_copy: Optional[str] = None
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


class Event(SQLModel, table=True):
    """Append-only event log for analytics + badge evaluation.

    `kind` is the verb ("push_sent", "push_replied", "agent_authorized",
    "agent_revoked", "agent_muted", "app_opened", "delete_account_canceled",
    ...). Actor is whoever triggered the event — usually a user or an agent.
    Meta is whatever's relevant for that kind. Designed to be cheap to write
    and dumpable to a real warehouse later.
    """
    id: str = Field(default_factory=gen_uuid, primary_key=True)
    kind: str = Field(index=True)
    actor_kind: str = Field(index=True)            # "user" | "agent" | "system"
    actor_id: Optional[str] = Field(default=None, index=True)
    meta: Optional[str] = None                     # JSON string; small payloads only
    created_at: datetime = Field(default_factory=datetime.utcnow, index=True)


class Badge(SQLModel, table=True):
    """Static badge definition, seeded at startup from services/badges.py."""
    id: str = Field(primary_key=True)              # short slug, e.g. "first-ping"
    scope: str = Field(index=True)                 # "agent" | "user" | "pair"
    name_zh: str
    name_en: str
    description_zh: str
    description_en: str
    icon: str                                      # SF Symbol or emoji
    secret: bool = Field(default=False)
    early: bool = Field(default=False)             # surfaced as locked-list filter


class EarnedBadge(SQLModel, table=True):
    id: str = Field(default_factory=gen_uuid, primary_key=True)
    badge_id: str = Field(foreign_key="badge.id", index=True)
    user_id: Optional[str] = Field(default=None, foreign_key="appuser.id", index=True)
    agent_id: Optional[str] = Field(default=None, foreign_key="agent.id", index=True)
    earned_at: datetime = Field(default_factory=datetime.utcnow, index=True)
    notified: bool = Field(default=False)          # have we sent the celebration push?


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
    description: Optional[str] = None
    logo_url: Optional[str] = None
    agent_type: Optional[str] = None  # one of AGENT_TYPES keys


class AgentLoginRequest(SQLModel):
    email: str
    password: str


class AgentResponse(SQLModel):
    id: str
    name: str
    email: str
    api_key: str
    webhook_url: Optional[str]
    description: Optional[str] = None
    logo_url: Optional[str] = None
    agent_type: Optional[str] = None
    created_at: datetime


class PushRequest(SQLModel):
    user_key: str
    category_id: str
    title: str
    body: str
    subtitle: Optional[str] = None      # iOS native middle-line text
    image_url: Optional[str] = None     # remote image, attached by NSE
    # Bark-style extras
    level: Optional[str] = None         # passive | active | timeSensitive | critical
    sound: Optional[str] = None         # custom sound name (must exist in app bundle)
    badge: Optional[int] = None         # app icon badge count
    group: Optional[str] = None         # notification thread identifier (groups related pushes)
    url: Optional[str] = None           # tap notification body to open this URL
    auto_copy: Optional[str] = None     # text auto-copied to clipboard on tap
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
    level: Optional[str] = None
    sound: Optional[str] = None
    badge: Optional[int] = None
    group: Optional[str] = None
    url: Optional[str] = None
    auto_copy: Optional[str] = None
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
    agent_type: Optional[str] = None
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
