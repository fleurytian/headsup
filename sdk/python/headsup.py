"""HeadsUp Python SDK — single-file, no install needed.

Drop this file into your agent project. Only dependency: `requests`.

Usage:
    from headsup import HeadsUp

    bot = HeadsUp(api_key="pk_xxx")  # or env HEADSUP_API_KEY

    # Built-in category
    bot.push(user_key="uk_xxx", category="confirm_reject",
             title="支付确认", body="是否同意支付 ¥99?",
             data={"order_id": "ord_123"})

    # Custom category
    bot.create_category("pay_or_wait", buttons=[
        {"id": "pay",  "label": "立即支付", "icon": "checkmark.circle.fill"},
        {"id": "wait", "label": "稍后再说", "icon": "clock.fill"},
    ])
    bot.push(user_key="uk_xxx", category="pay_or_wait",
             title="美团外卖", body="黄焖鸡 ¥39")

    # List bound users
    for u in bot.users():
        print(u["user_key"])

    # Verify a webhook payload's signature in your handler:
    if not HeadsUp.verify_signature(body_bytes, signature_header, api_key):
        return 401

See docs/skill.md for the full protocol description.
"""
from __future__ import annotations

import hashlib
import hmac
import os
from typing import Any, Iterable

import requests

DEFAULT_BASE_URL = "https://api.headsup.md"


class HeadsUpError(Exception):
    def __init__(self, status: int, body: Any):
        self.status = status
        self.body = body
        super().__init__(f"HeadsUp API error {status}: {body}")


class HeadsUp:
    def __init__(
        self,
        api_key: str | None = None,
        base_url: str | None = None,
        timeout: float = 10.0,
    ):
        self.api_key = api_key or os.environ.get("HEADSUP_API_KEY")
        if not self.api_key:
            raise ValueError("HeadsUp api_key required (pass it or set HEADSUP_API_KEY)")
        self.base_url = (base_url or os.environ.get("HEADSUP_BASE_URL") or DEFAULT_BASE_URL).rstrip("/")
        self.timeout = timeout
        self._session = requests.Session()
        self._session.headers.update({"X-API-Key": self.api_key})

    # ── Push ────────────────────────────────────────────────────────────────

    def push(
        self,
        user_key: str,
        category: str,
        title: str,
        body: str,
        subtitle: str | None = None,
        image_url: str | None = None,
        data: dict | None = None,
        ttl: int = 3600,
        message_id: str | None = None,
    ) -> dict:
        """Send a single push to one user. Returns {message_id, status, created_at}.

        Length limits enforced server-side:
          title    ≤ 50 chars
          subtitle ≤ 80 chars (optional second line)
          body     ≤ 200 chars
          image_url ≤ 500 chars, must be http(s)://

        Markdown markers in title/body/subtitle are stripped (iOS doesn't render markdown).
        Newlines (\\n) and emoji are preserved.
        """
        payload = {
            "user_key": user_key,
            "category_id": category,
            "title": title,
            "body": body,
            "ttl": ttl,
        }
        if subtitle is not None:
            payload["subtitle"] = subtitle
        if image_url is not None:
            payload["image_url"] = image_url
        if data is not None:
            payload["data"] = data
        if message_id:
            payload["message_id"] = message_id
        return self._post("/v1/push", payload)

    def ask(
        self,
        user_key: str,
        category: str,
        title: str,
        body: str,
        subtitle: str | None = None,
        image_url: str | None = None,
        data: dict | None = None,
        timeout: float = 60.0,
        poll_interval: float = 1.5,
    ) -> dict | None:
        """High-level: send a push and synchronously wait for the user's response.

        Returns the response dict (with `button_id`, `button_label`, `data`, ...)
        or None if `timeout` elapses before the user taps any button.

        This is the primary entry point for **local agents** that cannot host a webhook.

        See `push()` for length limits and markdown handling.
        """
        import time as _time
        msg = self.push(user_key=user_key, category=category, title=title,
                        body=body, subtitle=subtitle, image_url=image_url,
                        data=data, ttl=int(timeout) + 60)
        message_id = msg["message_id"]
        deadline = _time.time() + timeout
        while _time.time() < deadline:
            responses = self._get(f"/v1/responses?message_id={message_id}&limit=1")
            if responses:
                return responses[0]
            _time.sleep(poll_interval)
        return None

    def responses(self, since: float | None = None, limit: int = 50) -> list[dict]:
        """Poll for any responses across all your messages. For long-running agents."""
        path = f"/v1/responses?limit={limit}"
        if since is not None:
            path += f"&since={since}"
        return self._get(path)

    def broadcast(
        self,
        user_keys: Iterable[str],
        category: str,
        title: str,
        body: str,
        data: dict | None = None,
        ttl: int = 3600,
    ) -> dict:
        """Send the same push to up to 100 users."""
        payload = {
            "user_keys": list(user_keys),
            "category_id": category,
            "title": title,
            "body": body,
            "ttl": ttl,
        }
        if data is not None:
            payload["data"] = data
        return self._post("/v1/push/broadcast", payload)

    # ── Categories (custom button templates) ────────────────────────────────

    def create_category(self, name: str, buttons: list[dict]) -> dict:
        """Create or replace a custom button template.

        buttons = [{"id": "pay", "label": "立即支付", "icon": "checkmark.circle.fill"}, ...]
        """
        return self._post("/v1/categories", {"name": name, "buttons": buttons})

    def list_categories(self) -> list[dict]:
        return self._get("/v1/categories")

    def update_category(self, name: str, buttons: list[dict]) -> dict:
        return self._patch(f"/v1/categories/{name}", {"name": name, "buttons": buttons})

    def delete_category(self, name: str) -> None:
        self._delete(f"/v1/categories/{name}")

    # ── Users ──────────────────────────────────────────────────────────────

    def users(self) -> list[dict]:
        """Return all users currently bound to this agent."""
        return self._get(f"/v1/users")

    def revoke_user(self, user_key: str) -> None:
        self._delete(f"/v1/users/{user_key}")

    # ── Messages (sent push history) ───────────────────────────────────────

    def messages(self, page: int = 1, page_size: int = 20) -> list[dict]:
        return self._get(f"/v1/messages?page={page}&page_size={page_size}")

    def message(self, message_id: str) -> dict:
        return self._get(f"/v1/messages/{message_id}")

    # ── Auth / agent self ──────────────────────────────────────────────────

    def me(self) -> dict:
        return self._get("/v1/agents/me")

    @property
    def auth_link(self) -> str:
        """The permanent URL you share with users to onboard them."""
        agent_id = self.me()["id"]
        return f"{self.base_url}/authorize?agent_id={agent_id}"

    # ── Webhook verification ───────────────────────────────────────────────

    @staticmethod
    def verify_signature(body: bytes, signature_header: str, api_key: str) -> bool:
        """Verify the X-Webhook-Signature header on an incoming webhook."""
        expected = "sha256=" + hmac.new(api_key.encode(), body, hashlib.sha256).hexdigest()
        return hmac.compare_digest(expected, signature_header or "")

    # ── HTTP plumbing ──────────────────────────────────────────────────────

    def _request(self, method: str, path: str, json: Any = None) -> Any:
        url = self.base_url + path
        r = self._session.request(method, url, json=json, timeout=self.timeout)
        if not r.ok:
            try:
                body = r.json()
            except Exception:
                body = r.text
            raise HeadsUpError(r.status_code, body)
        if r.status_code == 204 or not r.content:
            return None
        return r.json()

    def _get(self, path: str) -> Any:    return self._request("GET", path)
    def _post(self, path: str, body: Any) -> Any:  return self._request("POST", path, body)
    def _patch(self, path: str, body: Any) -> Any: return self._request("PATCH", path, body)
    def _delete(self, path: str) -> Any: return self._request("DELETE", path)
