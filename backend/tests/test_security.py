"""Regression tests for the security holes Codex flagged.

Run:    cd backend && source .venv/bin/activate && python3 -m pytest tests/ -v
"""
import os
import sys
import secrets

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

# Ensure we hit a fresh sqlite for the test, isolated from dev db.
os.environ["DATABASE_URL"] = "sqlite:///./test_headsup.db"

from fastapi.testclient import TestClient

# Re-import after env is set so config picks it up
from main import api  # noqa: E402
from sqlmodel import Session, select  # noqa: E402
from database import engine  # noqa: E402
from models import AppUser, AuthorizationRequest, PushMessage  # noqa: E402


@pytest.fixture(scope="module")
def client():
    if os.path.exists("test_headsup.db"):
        os.remove("test_headsup.db")
    with TestClient(api) as c:
        yield c
    if os.path.exists("test_headsup.db"):
        os.remove("test_headsup.db")


@pytest.fixture
def authed_user():
    """Create a fake authed AppUser bypassing real Apple Sign In (we can't sign Apple JWTs in tests)."""
    with Session(engine) as session:
        u = AppUser(
            apple_user_id="test_apple_id_" + secrets.token_hex(4),
            session_token=secrets.token_urlsafe(32),
            apns_device_token="fake_token_" + secrets.token_hex(8),
        )
        session.add(u)
        session.commit()
        session.refresh(u)
        return {
            "id": u.id,
            "user_key": u.user_key,
            "session_token": u.session_token,
        }


@pytest.fixture
def agent(client):
    r = client.post("/v1/agents/register", json={
        "name": "Test Agent",
        "email": f"test_{secrets.token_hex(4)}@example.com",
        "password": "test_password_123",
        "webhook_url": "http://localhost:9090/webhook",
    })
    assert r.status_code == 201, r.text
    return r.json()


# ── P0-1: /v1/app/authorize/confirm requires Bearer auth ────────────────────

def test_confirm_authorization_rejects_unauthenticated(client, agent):
    """Without Bearer token, confirm must 401."""
    r = client.post("/v1/app/authorize/confirm", json={
        "token": "fake-token",
        "user_key": "uk_fake",
    })
    assert r.status_code == 401, f"Expected 401, got {r.status_code}: {r.text}"


def test_confirm_authorization_rejects_user_key_mismatch(client, agent, authed_user):
    """Even with valid session, confirm rejects if user_key in body doesn't match."""
    # Create an authorization request
    with Session(engine) as session:
        from datetime import datetime, timedelta
        from models import gen_auth_token
        ar = AuthorizationRequest(
            agent_id=agent["id"],
            token=gen_auth_token(),
            expires_at=datetime.utcnow() + timedelta(minutes=5),
        )
        session.add(ar)
        session.commit()
        token = ar.token

    r = client.post(
        "/v1/app/authorize/confirm",
        json={"token": token, "user_key": "uk_someoneelse"},
        headers={"Authorization": f"Bearer {authed_user['session_token']}"},
    )
    assert r.status_code == 403


def test_confirm_authorization_succeeds_with_matching_session(client, agent, authed_user):
    with Session(engine) as session:
        from datetime import datetime, timedelta
        from models import gen_auth_token
        ar = AuthorizationRequest(
            agent_id=agent["id"],
            token=gen_auth_token(),
            expires_at=datetime.utcnow() + timedelta(minutes=5),
        )
        session.add(ar)
        session.commit()
        token = ar.token

    r = client.post(
        "/v1/app/authorize/confirm",
        json={"token": token, "user_key": authed_user["user_key"]},
        headers={"Authorization": f"Bearer {authed_user['session_token']}"},
    )
    assert r.status_code == 200


# ── P0-2: /v1/app/actions/report requires Bearer auth ────────────────────────

def test_actions_report_rejects_unauthenticated(client):
    r = client.post("/v1/app/actions/report", json={
        "message_id": "any",
        "button_id": "confirm",
        "button_label": "Confirm",
    })
    assert r.status_code == 401


def test_actions_report_rejects_other_users_message(client, agent, authed_user):
    """A user must not be able to report on a message belonging to a different user."""
    # Create a second user + a message owned by them
    with Session(engine) as session:
        other = AppUser(
            apple_user_id="other_user_" + secrets.token_hex(4),
            session_token=secrets.token_urlsafe(32),
        )
        session.add(other)
        session.commit()
        session.refresh(other)
        msg = PushMessage(
            agent_id=agent["id"],
            user_id=other.id,
            title="x", body="y",
            category_id="confirm_reject",
        )
        session.add(msg)
        session.commit()
        message_id = msg.id

    # First user (authed_user) tries to report on other user's message
    r = client.post(
        "/v1/app/actions/report",
        json={"message_id": message_id, "button_id": "confirm", "button_label": "Confirm"},
        headers={"Authorization": f"Bearer {authed_user['session_token']}"},
    )
    assert r.status_code == 403


# ── P0-3: bindings endpoints don't trust path parameters ─────────────────────

def test_get_bindings_requires_auth(client):
    r = client.get("/v1/app/bindings")
    assert r.status_code == 401


def test_revoke_binding_requires_auth(client, agent):
    r = client.delete(f"/v1/app/bindings/{agent['id']}")
    assert r.status_code == 401


def test_revoke_binding_only_revokes_own(client, agent, authed_user):
    """Even with valid session, you can only revoke your own bindings."""
    # Create a binding for a DIFFERENT user
    with Session(engine) as session:
        other = AppUser(
            apple_user_id="other2_" + secrets.token_hex(4),
            session_token=secrets.token_urlsafe(32),
        )
        session.add(other)
        session.commit()
        session.refresh(other)
        from models import AgentUserBinding
        binding = AgentUserBinding(agent_id=agent["id"], user_id=other.id)
        session.add(binding)
        session.commit()

    # authed_user tries to revoke - should 404 (binding doesn't belong to them)
    r = client.delete(
        f"/v1/app/bindings/{agent['id']}",
        headers={"Authorization": f"Bearer {authed_user['session_token']}"},
    )
    assert r.status_code == 404


# ── P0: register-device requires auth (already had this but cement it) ──────

def test_register_device_requires_auth(client):
    r = client.post("/v1/app/register-device", json={"apns_device_token": "tok"})
    assert r.status_code == 401


# ── Healthcheck and basics still work ────────────────────────────────────────

def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_agent_register_login_flow(client):
    email = f"flow_{secrets.token_hex(4)}@example.com"
    r = client.post("/v1/agents/register", json={
        "name": "Flow Agent", "email": email, "password": "secret123"
    })
    assert r.status_code == 201
    api_key = r.json()["api_key"]

    r = client.get("/v1/agents/me", headers={"X-API-Key": api_key})
    assert r.status_code == 200
    assert r.json()["email"] == email
