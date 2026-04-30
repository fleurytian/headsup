# HeadsUp · PRD

> Version: 3.0  ·  Last updated: 2026-04-29  ·  Status: alpha shipping

Living document. Replaces the v2.0 draft. Reflects the product as actually built — not the plan, the result.

---

## 1. What HeadsUp is

A relay layer between AI agents and the user's notification bar.
Agents (Claude Code, Codex, Hermes, OpenClaw, custom scripts) want to ask their human user a small question — "approve this deploy?", "send this email?", "pick A or B?" — without making the user open an app. HeadsUp is the channel.

**Inverted engagement metric**: most products optimize for app opens. HeadsUp optimizes for **pushes delivered ÷ app opens**. We want that ratio to climb. The user's home screen is rare — the lock screen is where the product lives.

### One-line pitch
> "Let your agents give you a heads up by reading [skill.md](https://headsup.md/skill.md). Yes / No / Wait — without opening a thing."

### Non-goals
- Generic notification SaaS (we have opinions about agents)
- Self-hosted server (we are SaaS)
- A messaging app (no chat list, no DMs, no fee feed)
- Agent marketplace (you bring your agent)

---

## 2. Two principals

| | What they do | How they get in |
|---|---|---|
| **User** | iPhone owner. Receives pushes. Replies via lock-screen buttons. | iOS app (App Store) → Sign in with Apple. |
| **Agent** | Any program that wants to ask the user something. | Reads `https://headsup.md/skill.md`, calls `POST /v1/agents/register`, gets `pk_xxx` API key. |

The user invites each agent via a single-use authorization link. Both sides can sever the binding at any time.

---

## 3. Core flows

### 3.1 First-time setup (user)
1. Install app, Sign in with Apple → server creates `AppUser` keyed on `apple_user_id`, returns `user_key` + `session_token`.
2. iOS registers with APNs, sends device token via `POST /v1/app/register-device`.
3. Empty agent list → "Get a heads up" + copy-able instruction box.

### 3.2 Agent onboarding (agent)
1. Agent reads `skill.md` (versioned via `skill_version` line at the top so cached agents can re-fetch on diff).
2. Agent calls `POST /v1/agents/register` with name, email, optional `webhook_url`, `agent_type`, `description`, `logo_url`. Returns `agent_id` + `api_key` (shown once).
3. Agent calls `POST /authorize/initiate?agent_id=…` — returns an HTML page with embedded token-only deep link `headsup://authorize?token=…`.
4. Agent sends the link to the user.
5. User taps in Safari → "Open in HeadsUp" → app's `DeepLinkHandler` calls `POST /v1/app/authorize/confirm` with the token.

### 3.3 Push (agent → user → agent)
1. Agent: `POST /v1/push` with `user_key`, `category_id`, `title`, `body`, optional fields.
2. Server: validates lengths, resolves category to its iOS-side identifier, creates `PushMessage`, hands a background task off to APNs HTTP/2.
3. Apple's APNs delivers to the user's iPhone. NSE downloads `image_url` (right-side thumbnail) and `agent_avatar_url` (sender avatar via `INSendMessageIntent`); upgrades the banner to a Communication Notification (iOS 15+, gated by Apple-granted entitlement).
4. User long-presses on lock screen → sees agent buttons + Later + Copy. Taps one.
5. iOS: `didReceive` action handler calls `POST /v1/app/actions/report`.
6. Server: writes `WebhookDelivery`, fires webhook to agent (if `webhook_url` set, retries 5s/30s/5min/30min on non-2xx), publishes to SSE stream `/v1/responses/stream` (zero-polling channel for local agents), and exposes via `/v1/responses` polling endpoint as fallback.

### 3.4 The "later" path
Two ways the user can defer:
- Tap **Later / 稍后再说** on the notification (per-message).
- Inside agent detail view → **One-click defer all unread**, with confirmation alert. POST `/v1/app/bindings/<agent_id>/defer-all-unread` replies "later" to every unanswered push from that agent. Each reply still goes through the full delivery chain.

### 3.5 Retract (agent → undo)
Agent calls `POST /v1/push/<message_id>/retract` → server sends a silent push with `delete=1` → iOS `didReceiveRemoteNotification` removes the original from Notification Center. Useful when the situation moot before the user replies.

---

## 4. Architecture

```
                     ┌──────────────────┐
                     │  agent (anywhere) │
                     └──────────────────┘
                             │
          POST /v1/push        │      GET /v1/responses[/stream]
          POST /v1/agents/…    │      webhook → agent
                             ▼
         ┌─────────────────────────────────────┐
         │  HeadsUp backend (FastAPI on Aliyun)  │
         │  ┌─────────────────────────────┐    │
         │  │ Postgres                     │    │
         │  │  agent / appuser / binding   │    │
         │  │  pushmessage / delivery       │    │
         │  │  badge / earnedbadge / event  │    │
         │  └─────────────────────────────┘    │
         │  event_bus (in-process pub/sub)     │
         └────────────────┬───────────────────┘
                          │ APNs HTTP/2 + ES256 JWT
                          ▼
                 ┌──────────────────┐
                 │  Apple APNs       │
                 └──────────────────┘
                          │
                          ▼
            ┌─────────────────────────┐
            │  iOS device              │
            │   ┌────────────────┐    │
            │   │ NSE             │   │ ← downloads image, builds
            │   │  (Comm.Notif.)  │   │   INSendMessageIntent, sets
            │   └────────────────┘   │   sender avatar
            │   ┌────────────────┐   │
            │   │ HeadsUp app    │   │ ← SwiftUI; receives action
            │   │  (SwiftUI)     │   │   tap, posts to backend
            │   └────────────────┘   │
            └─────────────────────────┘
```

### Stack
- Backend: Python 3.12 / FastAPI / SQLModel / Postgres / httpx (HTTP/2 to APNs) / python-jose
- iOS: SwiftUI (iOS 16+), Notification Service Extension target, `Intents` framework for Communication Notifications
- SDK: single-file Python (`requests`-only); JS planned

### Production
- Aliyun HK Simple Application Server, $8/mo. SSH listens on a non-default port to dodge Aliyun's port-22 anti-DDoS scrubbing. Long-term: migrate to Hetzner SG / DigitalOcean SG (Codex's recommendation; SSH headache goes away).
- Domain `headsup.md` via nic.md → Cloudflare DNS (proxy off, DNS only) → Aliyun.
- Let's Encrypt via certbot; auto-renew via cron.
- One-worker uvicorn (in-process pub/sub for SSE; switch to Redis pub/sub when we need >1).
- Deploy: gist + curl pipe (Aliyun Cloud Assistant) — until we add deploy-key git-pull.

---

## 5. Data model

### Core
- **AppUser**: `apple_user_id` (unique, from Apple JWT sub), `user_key`, `session_token`, `apns_device_token`, `mute_until`.
- **Agent**: `id`, `email` (unique), `password_hash`, `api_key`, `webhook_url?`, `name`, `description?`, `logo_url?`, `agent_type`.
- **AgentUserBinding**: `(agent_id, user_id)` pair, `status ∈ {active, revoked}`.
- **PushMessage**: agent → user push; full payload (title, body, subtitle, image_url, level, sound, badge, group, url, auto_copy, category_id, data, ttl).
- **WebhookDelivery**: one per user button-tap; `button_id`, `button_label`, `category_id`, retry state.
- **AuthorizationRequest**: short-lived (30 min) single-use token used to bind an agent to a user.
- **Category**: per-agent custom button template; synced to iOS via silent push.

### New (this session)
- **Event** (kind, actor_kind, actor_id, meta, created_at) — append-only log; reserved for analytics.
- **Badge** (id, scope ∈ {agent,user,pair}, name_zh, name_en, description_zh, description_en, icon, secret, early) — static catalog seeded at startup.
- **EarnedBadge** (badge_id, user_id?, agent_id?, earned_at, notified) — one row per holder.

### Migrations
`SQLModel.metadata.create_all` only creates new tables; it doesn't ALTER existing ones. We added `migrate_add_missing_columns()` that ALTERs in any column the model has that the DB lacks (idempotent on every boot). Switch to Alembic when we need data migrations beyond schema diffs.

---

## 6. Notification UX

iOS hard-caps lock-screen actions at 4. Layout:

| Category | Actions |
|---|---|
| `info_only` (no agent buttons) | `[copy]` |
| Built-in 2-button (e.g. confirm_reject) | `[yes, no, later, copy]` |
| Custom up to 4 buttons | `[b1, b2, b3, b4]` (no later/copy) |

### Body suffix
Server appends a language-aware hint based on title+body CJK detection:
- Actionable → "  （长按选择回复）" / "(long-press to reply)"
- info_only → "  （仅通知，无需回复）" / "(notification only — no reply needed)"

### Agent identity in the banner
Two slots:
- **Sender avatar** (left/top of banner): `agent_avatar_url`. Server falls back to `agent.logo_url`, then to a generated `ui-avatars.com` image (initial on accent). Renders as Communication Notification sender face if Apple's `usernotifications.communication` entitlement is granted (we requested it; right-side thumbnail is the universal fallback).
- **Per-message thumbnail** (right): `image_url`. Optional, agent-controlled (charts, screenshots).

---

## 7. Badges (the 40-piece easter egg)

Core idea: humor over earnestness. Most badges are not goals; they're observations the system makes about you (or your agent) and writes down.

- **Scope**: 20 EARLY (first day to first week) + 20 LONG (1 month+). Agent-side and user-side equally split.
- **13 are secret** — locked-list doesn't show them; they appear when triggered.
- **Trigger style**: each push/reply/revoke/mute hits a small sync evaluator that runs cheap targeted queries; awarding inserts an `EarnedBadge` row.
- **Celebration**: user badges fire a `level=passive`, `category=info_only` APNs push titled "🎖 解锁: <name>" so the unlock arrives like a quiet notification, not a marketing nag.
- **UI**: Settings → 徽章 / Badges. Earned full color, locked silhouette. Tapping a locked badge silently triggers Curious Cat (the meta-badge for being curious).

Bilingual humor matters — every badge has separate ZH and EN copy, not a translation.

Examples:
- `tightrope` "钢丝党 / Tightrope" — wrote a body ≥ 180 chars, "距离 BODY_TOO_LONG 还有 19 字 / 19 chars from a 400 error"
- `mañana` "下次一定 / Mañana" — first time tapping "稍后再说"; "我们都说过这句 / Promises, promises"
- `cold-feet` "差点删号 / Cold Feet" — opened the delete-account dialog and tapped Cancel
- `crickets` "蛐蛐儿 / Crickets" — agent-side; 50+ pushes with response rate < 20%

Full list in `services/badges.py:BUILTIN_BADGES`.

---

## 8. App layout (current)

### Why open the app at all?

Most days a HeadsUp user shouldn't *need* to. Notifications are the product. The
app exists for three discrete reasons, in priority order:

- **P0 — react to a stuck push.** A notification got dismissed, the user ignored
  it, the lock-screen actions misfired, or they want to back-fill a reply. Goal:
  see what's unread per agent, fix it, get out.
- **P1 — manage who can reach me.** Add a new agent (paste an auth link),
  silence a noisy one, revoke one entirely. Lower-frequency than P0 but more
  consequential.
- **P2 — feel something.** Badges, stats, "you've answered 80% of your pushes
  this week." Pure delight; never blocking.

### Home
1. **(P0)** Status banners (notifications denied / offline / not-asked) — the app is broken until these clear; show them on top so the user can't miss them.
2. **(P0)** Clipboard auto-detect card — surfaces a pending `headsup://authorize?...` so onboarding is one tap from anywhere.
3. **(P2)** Eyebrow + today summary right — `agents · N` and `今日 12 · 已回 8 · 待回 1`. Small, one line. Not a hero.
4. **(P0/P1)** Agent list rows — avatar (server-tinted), name, last push title (truncated), "active 5m ago", unread chip + 🔕 mute chip. The unread chip is the thing the user came for; tapping the row drops them into Detail where they can reply, defer-all, mark-all-read, or mute.
5. Pull-to-refresh.

### Why no big "compose" CTA?
The user never *initiates* a push from this app. The agents do. So Home is a
status board, not a launchpad. Adding a hero compose button would lie about the
product.

### Empty state — first-time
Long onboarding: instruction box (paste-and-go for any AI), 3 step lines, Add Agent button.

### Empty state — returning (revoked all)
Short: "All clear / 一个都没了" + Add Agent + Sign Out escape hatch.

### Agent detail
Header (name + bound-at), 2 stat boxes (messages / responded), 'one-click defer N' button when unread > 0, history list with **inline reply buttons** for unanswered messages (you can reply from history if you missed the lock-screen banner).

### Settings
- DND (1h / 8h)
- Account: user_key + Copy
- Notifications: permission state + device token tail
- **You** (new): Badges / Your Data / Diagnose
- About: version, project page link, privacy policy, contact
- Sign Out
- Delete account (double-confirm; cascades; awards `cold-feet` if canceled)

### History (global)
Cross-agent push timeline; shows agent name eyebrow + INFO chip for info_only. Long-press any row to copy body or title+body.

---

## 9. Metrics + analytics

### User-facing (Settings → Your Data)
- Total received / total replied / response rate / median response time
- 24-hour activity histogram

### Internal (planned, schema in place)
- DAU / WAU / MAU
- Open:push ratio (target < 1:50 — opens are exception, not engagement)
- D1 / D7 / D30 retention
- Auth flow completion rate (start → success)
- Per-agent: response rate, mute-to-revoke ratio, time-to-first-push
- Stale-session frequency (how often `headsupSessionInvalid` fires)
- SSE connection duration / reconnect count
- APNs delivery success rate

`Event` table seeded; instrumentation pending. Next step: `event_log()` helper called from key handlers, plus a `/v1/admin/metrics` for an internal web dashboard. **No third-party analytics SDK** by design — reduces App Privacy disclosure surface and keeps user data on our infra.

---

## 10. Security & privacy

- **Apple Sign In**: identity-token verified server-side (signature, iss, aud, exp). Nonce verification still pending — Codex P0, deferred until we test the full flow.
- **Agent auth**: `X-API-Key: pk_xxx` (random URL-safe 32 bytes); also accepts `Authorization: Bearer pk_xxx`.
- **App auth**: bearer `session_token` per user; auto-rotated on Apple re-sign-in.
- **Webhook signing**: HMAC-SHA256 of body with the agent's `api_key`; agent verifies in `X-Webhook-Signature` header.
- **Data deletion**: hard delete on Settings → Delete Account. Cascades bindings + messages + deliveries + the user row. No soft-delete copy retained.
- **Privacy policy** at `https://headsup.md/privacy`. App Store Connect's Nutrition Label declares: Apple ID identifier, APNs device token, name, email, user content (notification text). All linked, none tracked.
- **Apple guideline 2.5.2** (vibe-coding crackdown): HeadsUp itself does NOT run AI, NOT execute downloaded code, NOT allow users to build apps inside it. Reviewer note in `~/Desktop/headsup-app-store-draft.md` is explicit.

---

## 11.5. Apple App Review prep (Nov 2025 guideline update)

Apple updated **Guideline 5.1.2(i)** on 2025-11-13 to require explicit user
consent and disclosure when an app shares personal data with third-party AI
(LLMs etc.). HeadsUp is a delivery channel, not an AI app, but every reply the
user sends is being routed to a third-party agent that runs an LLM, so the
rule applies. The framing is "interactive notifications routed to user-authorized
agents," not "AI assistant."

Before App Store submission:

1. **Per-agent consent screen** when registering an agent: name + "your replies
   will be sent to this third party" + opt-in toggle. Mirror identical text in
   the privacy policy and the App Privacy questionnaire.
2. **Revocable in Settings** — already done (swipe-left revoke + per-agent mute).
   5.1.2(i) requires "ongoing control."
3. **App Store description**: avoid "AI assistant" / "powered by GPT" in title
   or subtitle; that invites Guideline 4.2 (Minimum Functionality) thin-wrapper
   scrutiny. Use "Interactive notifications" framing.
4. **Don't gate functionality on push permission** (5.1.2 explicit prohibition):
   the home screen still has to be useful even if the user denied notifications.
   StatusBanner is the pattern — done.
5. Submission must use Xcode 26 / iOS 26 SDK (mandatory from April 2026).
6. **Communication Notifications entitlement review note**: state explicitly that
   replies are user-initiated and authorized per-agent, not autonomous AI output.

Sources: Apple developer news 2025-11-13, App Review Guidelines 5.1.2(i) +
4.7 + 4.2.

## 11. Outstanding (top of the list)

| | |
|---|---|
| **App Store Connect setup** | Subtitle / description / screenshots / categories. Drafts in `~/Desktop/headsup-app-store-draft.md`. |
| **`com.apple.developer.usernotifications.communication` entitlement** | Email request to Apple. Drafted in `~/Desktop/headsup-apple-entitlement-request.md`. 1-3 weeks. |
| **Apple Sign In nonce** | Codex P0 from 4/27. Will touch login flow — held until we have a real test. |
| **API rate limit** | Per-agent quota (Free 100/mo). Currently no throttle. |
| **Migrate to Hetzner SG / DO SG** | Aliyun SSH scrubbing makes deploys painful. Backend works fine; the problem is operational. |
| **Apple Sign In nonce + 1001 cancellation handling** | iOS shows a clearer retry UX when Apple cancels. |
| **Internal analytics dashboard** | Web only; one user (you). Reads `Event` + DB joins. |

---

## 12. Roadmap

**v1.x (now → 2 weeks)**
- App Store submission (real first attempt)
- Apple Sign In nonce
- API rate limit (per-agent quota)
- Per-agent lock-screen mute (Bark's MuteProcessor pattern; needs App Group)
- NSE plist handoff for offline history

**v1.5 (1-2 months)**
- LONG-game badges land
- Home Screen Widget (recent N pushes; per-agent filter via WidgetConfigurationIntent)
- Notification Content Extension (rich expanded view)
- Internal metrics dashboard

**v2.0 (TBD)**
- E2E ciphertext (`ciphertext` field, AES-CBC; server + APNs blind to body)
- Multi-device per user (currently one APNs token per user; need device list)
- Agent-side dashboard at /dashboard (already exists; needs polish + agent_type/logo fields exposed)
- Node.js SDK
- Pricing tier launch (¥9.9/year Pro)

---

## 13. Identity / contact

- Brand: **HeadsUp** (App Store listing may be `HeadsUp · md` if `HeadsUp` taken)
- Domain: **headsup.md**
- Apple Developer Team: `N74WZGGX8W`
- iOS Bundle ID: `md.headsup.app`
- APNs Key: `576B75C7U9` (`.p8` in `~/projects/headsup/backend/secrets/`, gitignored)
- Code: <https://github.com/fleurytian/headsup> (public, AGPL-3.0)
- Server: Aliyun HK SWAS, $8/mo (IP looked up via DNS on `headsup.md`)
- Server credentials: `~/.headsup/credentials.env` (chmod 600 — never paste in chat)

---

*This PRD is the source of truth for "what HeadsUp is right now". Update on every substantive change.*
