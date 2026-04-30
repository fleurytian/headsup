"""Short-lived image hosting for agent push attachments.

Why this exists: NSE attaches an image to a push by fetching `image_url`
from the payload at delivery time. Most agents don't have a public web
host, so they had to find their own (catbox, Imgur, S3 presigned URL...).
This endpoint lets them upload to headsup.md directly and get a URL back.

Constraints (intentionally tight):

  • Auth:        Bearer api_key (agent identity)
  • File size:   ≤ 2 MB per image
  • MIME:        png / jpg / jpeg / webp
  • Quota:       5 images / agent / UTC day
  • TTL:         1 hour default, 24 hours max
  • URL shape:   https://headsup.md/u/<24-char-token>.<ext>
                 (random urlsafe; security is URL-unguessability,
                  same threat model as Slack / Imgur)

After expiry the row + the file on disk are both reaped by a periodic
sweep (see services/uploads_cleanup.sweep_expired). NSE will then 404 if
it still tries to fetch the old URL — caller should always upload anew
for each push, not cache.

Agents are still free to host images on catbox / their own CDN and pass
that URL straight through `push.image_url`. This endpoint is a
convenience, not a requirement.
"""
from __future__ import annotations

import base64
import hashlib
import secrets
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Depends, File, Form, HTTPException, Response, UploadFile
from fastapi.responses import FileResponse
from sqlmodel import Session, func, select

from config import settings
from database import get_session
from deps import get_current_agent
from models import Agent, UploadedImage

router = APIRouter(tags=["uploads"])

# ── Tunables ─────────────────────────────────────────────────────────────────
MAX_BYTES         = 2 * 1024 * 1024       # 2 MB
DEFAULT_TTL_MIN   = 60                    # 1 hour
MAX_TTL_MIN       = 60 * 24               # 24 hours
DAILY_QUOTA       = 5                     # per agent per UTC day
ALLOWED_EXTS      = {"png", "jpg", "jpeg", "webp"}
MIME_BY_EXT       = {
    "png":  "image/png",
    "jpg":  "image/jpeg",
    "jpeg": "image/jpeg",
    "webp": "image/webp",
}

# Files live under <repo>/backend/uploads (not <static>) so they're never
# served via the bundled-static route. We mount our own GET endpoint with
# expiry-aware logic instead.
UPLOAD_DIR = Path(__file__).resolve().parent.parent / "uploads"
UPLOAD_DIR.mkdir(exist_ok=True)


def _gen_token() -> str:
    # 18 bytes → 24 urlsafe chars; 144 bits of entropy.
    return secrets.token_urlsafe(18)[:24]


def _ext_from_upload(upload: UploadFile) -> str:
    # Prefer the filename extension; fall back to the content-type.
    name = (upload.filename or "").lower()
    if "." in name:
        ext = name.rsplit(".", 1)[1]
        if ext in ALLOWED_EXTS:
            return ext
    ct = (upload.content_type or "").lower()
    for ext, mime in MIME_BY_EXT.items():
        if mime == ct:
            return ext
    raise HTTPException(415, f"Only {', '.join(sorted(ALLOWED_EXTS))} are accepted")


# ── POST /v1/upload ──────────────────────────────────────────────────────────

@router.post("/upload", status_code=201)
async def upload_image(
    file: UploadFile = File(...),
    ttl_minutes: Optional[int] = Form(None),
    session: Session = Depends(get_session),
    agent: Agent = Depends(get_current_agent),
):
    """Upload a short-lived image. Returns the URL the NSE will fetch."""
    ext = _ext_from_upload(file)

    # Read with a hard cap so a malicious agent can't exhaust memory.
    blob = await file.read(MAX_BYTES + 1)
    if len(blob) > MAX_BYTES:
        raise HTTPException(413, f"Image must be ≤ {MAX_BYTES // 1024 // 1024} MB")
    if not blob:
        raise HTTPException(400, "Empty file")

    # Quota: 5 successful uploads per UTC day.
    day_start = datetime.utcnow().replace(hour=0, minute=0, second=0, microsecond=0)
    used_today = session.exec(
        select(func.count()).select_from(UploadedImage).where(
            UploadedImage.agent_id == agent.id,
            UploadedImage.created_at >= day_start,
        )
    ).first() or 0
    if used_today >= DAILY_QUOTA:
        raise HTTPException(
            429,
            f"Daily upload quota exceeded ({DAILY_QUOTA}/UTC-day). "
            "Use a public image host (e.g. catbox.moe) for additional images.",
        )

    # Pick TTL.
    ttl = ttl_minutes if ttl_minutes is not None else DEFAULT_TTL_MIN
    if ttl < 1 or ttl > MAX_TTL_MIN:
        raise HTTPException(400, f"ttl_minutes must be 1..{MAX_TTL_MIN}")

    token = _gen_token()
    sha   = hashlib.sha256(blob).hexdigest()
    expires_at = datetime.utcnow() + timedelta(minutes=ttl)

    path = UPLOAD_DIR / f"{token}.{ext}"
    path.write_bytes(blob)

    row = UploadedImage(
        token=token, agent_id=agent.id, ext=ext,
        bytes=len(blob), sha256=sha, expires_at=expires_at,
    )
    session.add(row)
    session.commit()

    base = settings.base_url.rstrip("/")
    return {
        "image_url":  f"{base}/u/{token}.{ext}",
        "expires_at": expires_at.isoformat() + "Z",
        "bytes":      len(blob),
        "ttl_minutes": ttl,
        "quota_used":  used_today + 1,
        "quota_remaining": DAILY_QUOTA - (used_today + 1),
    }


# ── Public GET /u/<token>.<ext> ──────────────────────────────────────────────
# Mounted at the API root so URLs are short. NSE fetches with no auth.

public_router = APIRouter(tags=["uploads-public"])


@public_router.get("/u/{token}.{ext}")
def fetch_image(token: str, ext: str, session: Session = Depends(get_session)):
    if ext not in ALLOWED_EXTS:
        raise HTTPException(404, "Not found")
    if len(token) != 24 or any(c not in
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        for c in token):
        raise HTTPException(404, "Not found")
    row = session.get(UploadedImage, token)
    if not row or row.ext != ext:
        raise HTTPException(404, "Not found")
    if row.expires_at < datetime.utcnow():
        # Don't leak whether it ever existed.
        raise HTTPException(404, "Not found")
    path = UPLOAD_DIR / f"{token}.{ext}"
    if not path.exists():
        raise HTTPException(404, "Not found")
    return FileResponse(
        path,
        media_type=MIME_BY_EXT[ext],
        # Honor the TTL — let CDNs / browser cache up to (but not past)
        # expiry, then drop. Image won't change so immutable is safe
        # within the lifetime.
        headers={
            "Cache-Control": (
                f"public, max-age={max(60, int((row.expires_at - datetime.utcnow()).total_seconds()))}, "
                "immutable"
            ),
        },
    )
