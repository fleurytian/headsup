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


# Hint suffixes appended to the body. We pick the language by sniffing CJK
# in title+body — the agent's user-facing wording sets the tone, regardless
# of where the agent itself runs.
HINT_REPLY_ZH    = "  （长按选择回复）"
HINT_REPLY_EN    = "  (long-press to reply)"
HINT_INFO_ZH     = "  （仅通知，无需回复）"
HINT_INFO_EN     = "  (notification only — no reply needed)"


def _is_chinese_text(s: str) -> bool:
    return any("一" <= c <= "鿿" for c in s or "")


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
    apns_endpoint = f"{host}/3/device/{device_token}"

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
            resp = await client.post(apns_endpoint, content=json.dumps(payload), headers=headers)
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
    level: Optional[str] = None,
    sound: Optional[str] = None,
    badge: Optional[int] = None,
    group: Optional[str] = None,
    url: Optional[str] = None,
    auto_copy: Optional[str] = None,
    agent_id: Optional[str] = None,
    agent_name: Optional[str] = None,
    agent_avatar_url: Optional[str] = None,
) -> tuple[bool, str]:
    try:
        token = _get_apns_token()
    except Exception as e:
        return False, f"apns_config_error: {e}"

    host = APNS_HOST_PROD if settings.apns_production else APNS_HOST_DEV
    apns_endpoint = f"{host}/3/device/{device_token}"

    title = strip_markdown(title)
    body = strip_markdown(body)
    if subtitle:
        subtitle = strip_markdown(subtitle)

    # Append a hint to the body so users know whether to act.
    # Language picked from the agent's actual title+body wording.
    is_zh = _is_chinese_text((title or "") + (body or ""))
    if category_id == "info_only":
        hint = HINT_INFO_ZH if is_zh else HINT_INFO_EN
    else:
        hint = HINT_REPLY_ZH if is_zh else HINT_REPLY_EN
    # Don't double-append on retries — be tolerant of either-language presence.
    already_hinted = any(h in body for h in (HINT_REPLY_ZH, HINT_REPLY_EN, HINT_INFO_ZH, HINT_INFO_EN))
    body_with_hint = body if already_hinted else body + hint

    alert: dict = {"title": title, "body": body_with_hint}
    if subtitle:
        alert["subtitle"] = subtitle

    aps: dict = {
        "alert": alert,
        "category": category_id,
        "sound": (sound + ".caf") if (sound and sound != "default") else "default",
    }
    if badge is not None:
        aps["badge"] = badge
    if group:
        aps["thread-id"] = group
    if level in {"passive", "active", "timeSensitive", "critical"}:
        aps["interruption-level"] = level
    # NSE needs to run whenever there's an image to download — the per-message
    # `image_url` (right-side thumbnail) OR the agent_avatar_url that becomes
    # the Communication-Notification sender face.
    if image_url or agent_avatar_url:
        aps["mutable-content"] = 1

    payload = {"aps": aps, "message_id": message_id}
    if image_url:
        payload["image_url"] = image_url           # right-side thumbnail (optional, agent-set)
    if url:
        payload["url"] = url
    if auto_copy:
        payload["auto_copy"] = auto_copy
    if data:
        payload["data"] = data
    # Sender identity — the iOS NSE turns these into a Communication
    # Notification (iOS 15+) so the banner shows the agent as the sender,
    # avatar at the top, replacing what would otherwise be the host app icon.
    if agent_id:
        payload["agent_id"] = agent_id
    if agent_name:
        payload["agent_name"] = agent_name
    if agent_avatar_url:
        payload["agent_avatar_url"] = agent_avatar_url

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
            resp = await client.post(apns_endpoint, content=json.dumps(payload), headers=headers)
            if resp.status_code == 200:
                return True, "ok"
            error = resp.json().get("reason", "unknown") if resp.content else "empty"
            return False, error
    except Exception as e:
        return False, str(e)
