"""In-process pub/sub for SSE response streams.

Each connected agent gets its own bounded asyncio.Queue. When a user taps a
button, /v1/app/actions/report calls publish(agent_id, event) and any
subscribed streams get the event without polling.

Limitation: this is per-process. With multiple uvicorn workers an event
published on worker A is not seen by a stream on worker B. Run with
--workers 1 until we add Redis pub/sub. SSE is fine on a single worker —
asyncio handles concurrent connections.
"""
from __future__ import annotations

import asyncio
from collections import defaultdict
from typing import Any

# agent_id -> set of subscriber Queues
_subscribers: dict[str, set[asyncio.Queue]] = defaultdict(set)


async def publish(agent_id: str, event: dict[str, Any]) -> None:
    for q in list(_subscribers.get(agent_id, set())):
        try:
            q.put_nowait(event)
        except asyncio.QueueFull:
            # Slow consumer — drop the event. Webhook + polling fallback still cover.
            pass


def subscribe(agent_id: str, *, maxsize: int = 100) -> asyncio.Queue:
    q: asyncio.Queue = asyncio.Queue(maxsize=maxsize)
    _subscribers[agent_id].add(q)
    return q


def unsubscribe(agent_id: str, q: asyncio.Queue) -> None:
    subs = _subscribers.get(agent_id)
    if subs is not None:
        subs.discard(q)
        if not subs:
            _subscribers.pop(agent_id, None)


def subscriber_count(agent_id: str) -> int:
    return len(_subscribers.get(agent_id, set()))
