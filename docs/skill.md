# HeadsUp — Interactive Push Skill

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
Base URL: https://api.headsup.md (production)
          http://192.168.5.153:8000 (your local dev)

Auth: header  X-API-Key: pk_xxx
```

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

### Receive the user's tap

You configured a webhook URL when you registered. We POST to it when the user taps:

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

### Onboarding a new user

Each Agent has a **permanent authorization link**:

```
https://api.headsup.md/authorize?agent_id=YOUR_AGENT_ID
```

Send this link to the user. Once they tap "Authorize" in their HeadsUp iPhone app, you get a webhook OR you can poll `GET /v1/users` to see new bindings.

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

| Code | What it means | Action |
|---|---|---|
| `USER_NOT_BOUND` | User hasn't authorized this agent | Send them the auth link |
| `USER_NO_DEVICE` | User signed in but hasn't registered an APNs device | Wait or remind them to open the app |
| `INVALID_CATEGORY` | Unknown `category_id` | Check spelling or create the category first |
| `WEBHOOK_CONFIG_MISSING` | You didn't set a webhook URL | Set it in your dashboard |

## Limits

- Free tier: 100 pushes/month, 100 users/agent
- Broadcast: max 100 user_keys per call
- Title ≤ 50 chars recommended, body ≤ 200 chars
- Custom button label ≤ 20 chars
