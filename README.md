# HeadsUp · `headsup.md`

> Let your AI send you notifications with reply options. Yes / No / Wait — without opening a thing. (Agents learn the protocol from [skill.md](https://headsup.md/skill.md).)

iOS push notification platform for AI agents. Agents send notifications with tappable buttons, users reply from the lock screen, agents receive the result via webhook, SSE, or polling.

[![License: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

## Layout

```
backend/        FastAPI + SQLModel + APNs HTTP/2 + Postgres
docs/           skill.md — agent-facing protocol
ios/            SwiftUI iPhone app + Notification Service Extension
sdk/python/     Single-file Python SDK
```

## Local dev

```bash
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # then fill in APNS_*, SECRET_KEY
uvicorn main:api --reload
```

For iOS:
```bash
cd ios
xcodegen          # generates HeadsUp.xcodeproj from project.yml
open HeadsUp.xcodeproj
```

> The `.xcodeproj/` is gitignored. Re-run `xcodegen` whenever new
> source files appear (after `git pull`, after adding `.swift` files).
> Otherwise Xcode will report `Cannot find 'X' in scope` for the new
> files even though they're on disk.

You'll need an Apple Developer account, an APNs `*.p8` key, and your own bundle id to ship pushes from your fork. The default reference deployment lives at <https://headsup.md>.

## Status

The hosted instance at <https://headsup.md> is the canonical one, run by [@fleurytian](https://github.com/fleurytian). The iOS app submits to the App Store from there.

If you fork this and self-host, point your iOS build at your own backend (edit `ApiBaseURL` in `ios/HeadsUp/Info.plist`) and register a separate Apple bundle id.

## Secrets

Nothing sensitive lives in this repo. APNs `.p8` keys, server passwords, ADMIN_TOKEN, and any `.env` are gitignored. They live in `~/.headsup/credentials.env` on the operator's machine and are propagated to production only through env vars / SSH-tunneled file copy.

## Donations

In-app tip jar via StoreKit consumable IAP — three tiers from Settings → Tip Jar in the app.

## License

AGPL-3.0 — derivative works that run as a public service must publish their source.
