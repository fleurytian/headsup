"""Periodic sweep that deletes expired UploadedImage rows + their files.

Hooked from main.lifespan as a long-running asyncio Task. Cheap query
(indexed on expires_at) so we just run it every 5 minutes; no Celery,
no cron table.
"""
from __future__ import annotations

import asyncio
from datetime import datetime
from pathlib import Path

from sqlmodel import Session, select

SWEEP_INTERVAL_SECONDS = 5 * 60


async def sweep_loop():
    """Wake every 5 min, delete expired uploads. Resilient to errors."""
    from database import engine
    while True:
        try:
            await asyncio.to_thread(_sweep_once, engine)
        except Exception as e:
            # Don't let a transient DB blip kill the loop.
            print(f"[uploads_cleanup] sweep error: {e!r}")
        await asyncio.sleep(SWEEP_INTERVAL_SECONDS)


def _sweep_once(engine) -> int:
    """Delete files + rows whose expires_at has passed. Returns # deleted."""
    from models import UploadedImage
    from routers.uploads import UPLOAD_DIR

    now = datetime.utcnow()
    deleted = 0
    with Session(engine) as session:
        expired = session.exec(
            select(UploadedImage).where(UploadedImage.expires_at < now)
        ).all()
        for row in expired:
            path = UPLOAD_DIR / f"{row.token}.{row.ext}"
            try:
                path.unlink(missing_ok=True)
            except Exception as e:
                print(f"[uploads_cleanup] couldn't unlink {path}: {e!r}")
            session.delete(row)
            deleted += 1
        if deleted:
            session.commit()
    return deleted
