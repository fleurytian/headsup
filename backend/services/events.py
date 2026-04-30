"""Append-only event log helpers.

Cheap to write, dumpable later. Keep `meta` small — JSON-serialized via the
caller; we store the resulting string verbatim. Failures here must never
break the user-facing flow, so callers wrap in try/except.
"""
from __future__ import annotations
import json
from typing import Any, Optional
from sqlmodel import Session

from models import Event


def log(
    session: Session,
    *,
    kind: str,
    actor_kind: str,                # "user" | "agent" | "system"
    actor_id: Optional[str] = None,
    meta: Optional[dict[str, Any]] = None,
    commit: bool = True,
) -> None:
    """Insert one row. Callers should wrap in try/except — telemetry must
    never break primary flow."""
    payload = None
    if meta:
        try:
            payload = json.dumps(meta, default=str, ensure_ascii=False)
        except (TypeError, ValueError):
            payload = None
    ev = Event(
        kind=kind,
        actor_kind=actor_kind,
        actor_id=actor_id,
        meta=payload,
    )
    session.add(ev)
    if commit:
        session.commit()


def safe_log(session: Session, **kwargs) -> None:
    """log() that swallows all exceptions — for use in hot paths where the
    caller absolutely cannot fail because telemetry failed."""
    try:
        log(session, **kwargs)
    except Exception:
        # Best-effort. Don't even log the error here — it'd be too noisy
        # and we can recover state from the source-of-truth tables.
        pass
