# HeadsUp — Interactive Push Skill

`skill_version: 2026-04-29.3`  ·  `last_updated: 2026-04-29`

> Bump `skill_version` when anything below changes substantively. Agents that cache this doc should compare the version and re-fetch on mismatch. The version is the first thing the doc reveals so a `HEAD` or first-line read is enough to decide.

Send notifications to your user's iPhone with **tappable buttons**, and get the result back. Use when you need a yes/no, approve/reject, or pick-one decision **without** the user opening any app.

## When to use this

- Before doing something irreversible: `"OK to send $200 to Alice?"`
- Asking the user to pick: `"Which restaurant should I book?"`
- Asking for confirmation: `"Order 黄焖鸡 ¥39?"`
- Quick feedback: `"Was this helpful?"`

## When NOT to use

- Long answers (> 3 buttons of choice): use chat instead
- Free-text replies: not supported (yet)
- Time-sensitive < 10s decisions: APNs delivery is best-effort, can take seconds
- The user hasn't authorized you yet (you'll get `USER_NOT_BOUND`)

## API in one screen

```
Base URL: https://headsup.md     ← always. No api.* subdomain. No localhost.

Auth: header  X-API-Key: pk_xxx
```

### First-time setup — register yourself (do this once)

You need an `agent_id` + `api_key` before anything else. Production storage is independent of any other deployment, so dev or local agent records don't transfer.

```bash
curl -X POST https://headsup.md/v1/agents/register \
  -H "Content-Type: application/json" \
  -d '{
    "name":         "<your agent name>",
    "email":        "<unique email — used as login>",
    "password":     "<random long string, store it>",
    "agent_type":   "assistant",        // or coding | automation | monitor | companion | research | other
    "description":  "<one-line bio shown on the user's authorize screen>",
    "logo_url":     null,               // optional, https URL to a square image
    "webhook_url":  null                // optional; if null, use SSE or polling for responses
  }'
```

Response gives you `id` (agent_id) and `api_key` (pk_xxx). **Store both** — `api_key` is shown only once. After this, every other call uses `X-API-Key: <api_key>`.

### Send a push

```http
POST /v1/push
{
  "user_key":    "uk_xxx",            // who
  "category_id": "confirm_reject",    // which button preset (see below)
  "title":       "支付确认",
  "body":        "AI 助手代你支付 ¥99",
  "data":        { "order_id": "..." }  // optional, echoed back in webhook
}
```

### Built-in categories

| `category_id` | Buttons |
|---|---|
| `confirm_reject` | 确认 / 拒绝 |
| `yes_no` | 是 / 否 |
| `approve_cancel` | 批准 / 取消 |
| `choose_a_b` | 选项 A / 选项 B |
| `agree_decline` | 同意 / 婉拒 |
| `remind_later_skip` | 稍后提醒 / 跳过 |
| `action_dismiss` | 执行 / 忽略 |
| `feedback` | 有帮助 / 无帮助 |

### Custom categories

```http
POST /v1/categories
{
  "name": "pay_or_wait",
  "buttons": [
    {"id": "pay",  "label": "立即支付", "icon": "checkmark.circle.fill"},
    {"id": "wait", "label": "稍后再说", "icon": "clock.fill"}
  ]
}
```

Then push using `"category_id": "pay_or_wait"`. Created/updated categories sync to the user's iPhone via silent push within seconds — push immediately after create.

`icon` accepts SF Symbol names (https://developer.apple.com/sf-symbols/). Optional.

### Receive the user's tap — two ways

**A. Webhook (push to you)** — set when you register; we POST when the user taps:

```http
POST your-webhook-url
X-Webhook-Signature: sha256=...   // HMAC-SHA256 of body using your api_key
{
  "message_id":   "uuid",
  "user_key":     "uk_xxx",
  "agent_id":     "uuid",
  "button_id":    "pay",          // <-- which button they tapped
  "button_label": "立即支付",
  "category_id":  "pay_or_wait",
  "data":         { "order_id": "..." },
  "timestamp":    1714291200
}
```

Retried 5s / 30s / 5min / 30min on non-2xx.

**B. SSE stream (recommended for local agents)** — open one long HTTP connection, get pushed events with no polling:

```http
GET /v1/responses/stream
X-API-Key: pk_xxx
Accept: text/event-stream
→ ": connected"
  "data: {\"message_id\":\"uuid\",\"button_id\":\"pay\",...}"
  ": ping"     ← keep-alive every 20s
  "data: {...}"
```

Connect once, leave it open. Reconnect on disconnect. Works through any firewall (just outbound HTTPS). Same event shape as webhook minus `X-Webhook-Signature`.

**C. Polling (fallback)** — if SSE isn't available in your stack:

```http
GET /v1/responses?since=2026-04-29T00:00:00Z[&message_id=uuid]
X-API-Key: pk_xxx
```

Use `since=` for incremental pulls (advance to the latest `replied_at` after each response). Use `message_id=` to wait on **one specific** push. Recommended cadence: 1-2s while waiting on a specific message, otherwise 5-10s background.

The Python SDK's `bot.ask()` wraps SSE with polling fallback — `ask()` sends, blocks until response arrives, returns.

### Multi-session agents: correlate responses with `data`

If a single agent runs **multiple parallel sessions / tasks / users** (most non-trivial agents do), don't assume "the latest response is mine." Two pushes can interleave; a slow user can answer message A after you sent B; a webhook retry can land out of order.

**Pattern**: stamp identity into `data` on every push, match it back on the response.

```python
# When sending
push({
  "user_key": "uk_xxx",
  "category_id": "confirm_reject",
  "title": "Send the email?",
  "body": "Subject: weekly update — to engineering@",
  "data": {
    "session_id": "sess_8a3f",      # ← which session asked
    "task_id":    "task_42",        # ← which task is waiting
    "purpose":    "send_email",     # ← what kind of decision
    "draft_id":   "d_19283",        # ← any other context you'll need to act
  },
})

# When the response comes back (webhook OR SSE OR polling),
# `data` is echoed back verbatim. Route on session_id/task_id, not recency.
on_response(event):
  sess = event.data["session_id"]
  task = event.data["task_id"]
  resume(sess, task, button=event.button_id)
```

**Belt-and-suspenders**: also use `message_id` from the push response for exact-match polling — `GET /v1/responses?message_id=<id>` returns just that one tap. Use this when *one* specific push is what you're blocking on; use `data` correlation when many can be in flight at once.

### Onboarding a new user

Generate a single-use authorization link by POST'ing to `/authorize/initiate`:

```bash
curl -X POST https://headsup.md/authorize/initiate \
  -d "agent_id=YOUR_AGENT_ID"
# returns HTML page with embedded headsup://authorize?token=...&agent_id=... deep link
```

Send the user **either**:
- the `https://headsup.md/authorize?token=...&agent_id=...` URL — they tap in Safari, "Open in HeadsUp" button takes them through, **or**
- the `headsup://authorize?token=...&agent_id=...` deep link — they paste in app's "Add Agent" view

Tokens expire in 30 minutes. Once they tap "Authorize" in the app, you get a webhook OR poll `GET /v1/users` to see new bindings.

## Decision tree

```
Need user input?
├── Yes/No or 2-option pick → use a built-in or custom category, send push
├── Free-text reply         → not supported yet, fall back to chat
└── 3+ choices              → use multiple pushes or fall back to chat

User hasn't authorized you (USER_NOT_BOUND)?
└── Send them your auth link, wait for webhook saying they're bound

Need it logged + retried if they're offline?
└── HeadsUp already does this. Webhook is retried 5s/30s/5min/30min on failure.
```

## Common errors

Errors come back as `{"detail": {"code": "...", "message": "...", "solution"?: "..."}}`.

| Code | HTTP | What it means | Action |
|---|---|---|---|
| `USER_NOT_FOUND` | 404 | `user_key` doesn't exist | Check the key the user gave you |
| `USER_NOT_BOUND` | 400 | User hasn't authorized this agent | Send them your auth link from `/authorize/initiate` |
| `USER_NO_DEVICE` | 400 | User signed in but no APNs device yet | Ask them to open the app once |
| `USER_MUTED` | 429 | User has DND on; push won't deliver until expiry | Retry after `mute_until` |
| `INVALID_CATEGORY` | 400 | Unknown `category_id` | Use a built-in or create the category first |
| `TITLE_TOO_LONG` / `BODY_TOO_LONG` / `SUBTITLE_TOO_LONG` | 400 | Length cap exceeded | See limits below; truncate before sending |
| `INVALID_IMAGE_URL` | 400 | image_url not http(s) or too long | Provide an absolute URL, ≤ 200 chars |

## Limits

- Free tier: 100 pushes/month, 100 users/agent
- Broadcast: max 100 user_keys per call
- Title ≤ 50 chars recommended, body ≤ 200 chars
- Custom button label ≤ 20 chars
