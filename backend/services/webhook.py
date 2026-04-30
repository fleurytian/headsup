import asyncio
import hashlib
import hmac
import json
import logging
from datetime import datetime, timedelta

import httpx
from sqlmodel import Session, select

from config import settings
from database import engine
from models import Agent, WebhookDelivery

logger = logging.getLogger(__name__)

RETRY_DELAYS = [5, 30, 300, 1800]  # seconds: 5s, 30s, 5min, 30min


def _sign_payload(body: bytes, secret: str) -> str:
    sig = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return f"sha256={sig}"


async def deliver_webhook(delivery_id: str) -> None:
    with Session(engine) as session:
        delivery = session.get(WebhookDelivery, delivery_id)
        if not delivery:
            return
        # Silent mark-as-read receipts are stored as deliveries (so the unread
        # count clears) but should never be sent to the agent.
        if delivery.status == "suppressed":
            return

        agent = session.get(Agent, delivery.agent_id)
        if not agent or not agent.webhook_url:
            delivery.status = "failed"
            session.add(delivery)
            session.commit()
            return

        payload = {
            "message_id": delivery.message_id,
            "user_key": delivery.user_key,
            "agent_id": delivery.agent_id,
            "button_id": delivery.button_id,
            "button_label": delivery.button_label,
            "category_id": delivery.category_id,
            "data": json.loads(delivery.data) if delivery.data else {},
            "timestamp": int(delivery.created_at.timestamp()),
        }
        body = json.dumps(payload).encode()
        signature = _sign_payload(body, agent.api_key)

        delivery.attempts += 1
        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                resp = await client.post(
                    agent.webhook_url,
                    content=body,
                    headers={
                        "Content-Type": "application/json",
                        "X-Webhook-Signature": signature,
                        "X-HeadsUp-Agent-ID": agent.id,
                    },
                )
            if 200 <= resp.status_code < 300:
                delivery.status = "delivered"
                delivery.delivered_at = datetime.utcnow()
            else:
                _schedule_retry(delivery)
        except Exception as e:
            logger.warning(f"Webhook delivery failed for {delivery_id}: {e}")
            _schedule_retry(delivery)

        session.add(delivery)
        session.commit()


def _schedule_retry(delivery: WebhookDelivery) -> None:
    idx = min(delivery.attempts - 1, len(RETRY_DELAYS) - 1)
    if delivery.attempts > len(RETRY_DELAYS):
        delivery.status = "failed"
    else:
        delay = RETRY_DELAYS[idx]
        delivery.next_retry_at = datetime.utcnow() + timedelta(seconds=delay)


async def retry_loop() -> None:
    while True:
        await asyncio.sleep(5)
        try:
            with Session(engine) as session:
                pending = session.exec(
                    select(WebhookDelivery).where(
                        WebhookDelivery.status == "pending",
                        WebhookDelivery.next_retry_at <= datetime.utcnow(),
                    )
                ).all()

            for delivery in pending:
                asyncio.create_task(deliver_webhook(delivery.id))
        except Exception as e:
            logger.error(f"Retry loop error: {e}")
