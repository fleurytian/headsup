# HeadsUp · `headsup.md`

> Let your agents give you a heads up by reading [skill.md](https://headsup.md/skill.md). Yes / No / Wait — without opening a thing.

iOS push notification platform for AI agents. Agents send notifications with tappable buttons, users reply from the lock screen, agents receive the result via webhook, SSE, or polling.

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

## Production

Live at <https://headsup.md>. Backend on Aliyun HK SWAS at `47.83.199.33`. SSL via Let's Encrypt.

Deploy via Aliyun Cloud Assistant Run Command pulling from a private gist (see `~/Desktop/...` runbooks).

## Identity / secrets

Apple Developer Team `N74WZGGX8W`, Bundle ID `md.headsup.app`. APNs key + server password live in `~/.headsup/credentials.env` outside this repo. The `*.p8` and any `secrets/` directory are gitignored.

---
*This is a private repo. Don't share unless you're me.*
