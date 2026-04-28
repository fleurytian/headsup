import json
import time
from pathlib import Path
from typing import Optional
import httpx
from jose import jwt
from config import settings

APNS_HOST_PROD = "https://api.push.apple.com"
APNS_HOST_DEV = "https://api.sandbox.push.apple.com"

_token_cache: dict = {"token": None, "issued_at": 0}


def _get_apns_token() -> str:
    now = int(time.time())
    if _token_cache["token"] and now - _token_cache["issued_at"] < 3000:
        return _token_cache["token"]

    key_path = Path(settings.apns_private_key_path)
    if not key_path.exists():
        raise RuntimeError(f"APNs private key not found at {key_path}")

    private_key = key_path.read_text()
    token = jwt.encode(
        {"iss": settings.apns_team_id, "iat": now},
        private_key,
        algorithm="ES256",
        headers={"kid": settings.apns_key_id},
    )
    _token_cache["token"] = token
    _token_cache["issued_at"] = now
    return token


HINT_SUFFIX = "  （长按选择回复）"

# iOS notification display limits (chars). Hard caps; agent gets 400 if exceeded.
MAX_TITLE_LEN = 50
MAX_SUBTITLE_LEN = 80
MAX_BODY_LEN = 200
MAX_IMAGE_URL_LEN = 500


import re

# Conservative markdown stripper. iOS notifications don't render markdown,
# so strip the markers and keep the visible text.
_MARKDOWN_PATTERNS = [
    (re.compile(r"\*\*(.+?)\*\*", re.DOTALL), r"\1"),    # **bold** → bold
    (re.compile(r"__(.+?)__", re.DOTALL), r"\1"),         # __bold__ → bold
    (re.compile(r"(?<!\*)\*([^*\n]+?)\*(?!\*)"), r"\1"),  # *italic* → italic
    (re.compile(r"(?<!_)_([^_\n]+?)_(?!_)"), r"\1"),      # _italic_ → italic
    (re.compile(r"~~(.+?)~~", re.DOTALL), r"\1"),         # ~~strike~~ → strike
    (re.compile(r"`([^`\n]+)`"), r"\1"),                  # `code` → code
    (re.compile(r"\[([^\]]+)\]\([^)]+\)"), r"\1"),        # [label](url) → label
    (re.compile(r"^#+\s+", re.MULTILINE), ""),            # # heading → heading
]


def strip_markdown(text: str) -> str:
    """Remove markdown markers since iOS notifications render plain text only.
    Preserves newlines and emoji."""
    if not text:
        return text
    out = text
    for pat, repl in _MARKDOWN_PATTERNS:
        out = pat.sub(repl, out)
    return out


async def send_silent_push(device_token: str, custom_data: Optional[dict] = None) -> tuple[bool, str]:
    """Background-only push that wakes the app to refresh state. No alert shown."""
    try:
        token = _get_apns_token()
    except Exception as e:
        return False, f"apns_config_error: {e}"

    host = APNS_HOST_PROD if settings.apns_production else APNS_HOST_DEV
    url = f"{host}/3/device/{device_token}"

    payload = {"aps": {"content-available": 1}}
    if custom_data:
        payload.update(custom_data)

    headers = {
        "authorization": f"bearer {token}",
        "apns-topic": settings.apns_bundle_id,
        "apns-push-type": "background",
        "apns-priority": "5",
        "content-type": "application/json",
    }

    try:
        async with httpx.AsyncClient(http2=True, timeout=10.0) as client:
            resp = await client.post(url, content=json.dumps(payload), headers=headers)
            if resp.status_code == 200:
                return True, "ok"
            return False, resp.json().get("reason", "unknown") if resp.content else "empty"
    except Exception as e:
        return False, str(e)


async def send_push(
    device_token: str,
    title: str,
    body: str,
    category_id: str,
    message_id: str,
    data: Optional[dict] = None,
    ttl: int = 3600,
    subtitle: Optional[str] = None,
    image_url: Optional[str] = None,
) -> tuple[bool, str]:
    try:
        token = _get_apns_token()
    except Exception as e:
        return False, f"apns_config_error: {e}"

    host = APNS_HOST_PROD if settings.apns_production else APNS_HOST_DEV
    url = f"{host}/3/device/{device_token}"

    title = strip_markdown(title)
    body = strip_markdown(body)
    if subtitle:
        subtitle = strip_markdown(subtitle)

    body_with_hint = body if HINT_SUFFIX in body else body + HINT_SUFFIX

    alert: dict = {"title": title, "body": body_with_hint}
    if subtitle:
        alert["subtitle"] = subtitle

    aps: dict = {
        "alert": alert,
        "category": category_id,
        "sound": "default",
    }
    # Image attachment requires Notification Service Extension to download
    # the URL on-device. We set mutable-content=1 so iOS hands the payload
    # to the extension before showing the banner.
    if image_url:
        aps["mutable-content"] = 1

    payload = {"aps": aps, "message_id": message_id}
    if image_url:
        payload["image_url"] = image_url
    if data:
        payload["data"] = data

    headers = {
        "authorization": f"bearer {token}",
        "apns-topic": settings.apns_bundle_id,
        "apns-push-type": "alert",
        "apns-expiration": str(int(time.time()) + ttl),
        "apns-priority": "10",
        "content-type": "application/json",
    }

    try:
        async with httpx.AsyncClient(http2=True, timeout=10.0) as client:
            resp = await client.post(url, content=json.dumps(payload), headers=headers)
            if resp.status_code == 200:
                return True, "ok"
            error = resp.json().get("reason", "unknown") if resp.content else "empty"
            return False, error
    except Exception as e:
        return False, str(e)
