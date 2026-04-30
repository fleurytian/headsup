#!/bin/bash
#
# Interactive screenshot capture for App Store Connect.
#
# Boots the largest Pro Max simulator available (default iPhone 17 Pro
# Max — 6.9", which is what App Store Connect's "iPhone 6.9" Display"
# bucket wants), installs the latest Debug build, and waits for you to
# navigate the app manually. Each time you press [Enter] in this
# terminal, it captures a screenshot, saves it to `screenshots/`.
#
# Override the device with:
#   DEVICE_NAME="iPhone 17 Pro" bash scripts/screenshot.sh
#
# 5 captures, in this order:
#   1. onboarding   — Sign in with Apple page
#   2. home         — agent list with at least one agent + Setup
#                     Checklist visible
#   3. authorize    — Authorize page with consent toggle visible
#   4. detail       — agent detail with reply buttons + 一键已读 / 稍后再说
#   5. settings     — Settings → Demo section visible
#
# Output: 1290 × 2796 PNGs (the App Store Connect 6.7" display target).
#
# Usage:
#   cd ios && bash scripts/screenshot.sh
#
set -euo pipefail

DEVICE_NAME="${DEVICE_NAME:-iPhone 17 Pro Max}"  # override via env if needed
PROJECT="HeadsUp.xcodeproj"
SCHEME="HeadsUp"
OUT_DIR="$(pwd)/screenshots"

mkdir -p "$OUT_DIR"

echo "==> Locating $DEVICE_NAME simulator…"
DEVICE_ID=$(xcrun simctl list devices available -j 2>/dev/null \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    for d in devices:
        if d['name'] == '$DEVICE_NAME' and d['isAvailable']:
            print(d['udid'])
            sys.exit(0)
sys.exit(1)
" || true)

if [ -z "$DEVICE_ID" ]; then
    echo "Couldn't find an available '$DEVICE_NAME' simulator."
    echo "Available simulators:"
    xcrun simctl list devices available
    exit 1
fi

echo "    using $DEVICE_ID"

echo "==> Booting simulator (no-op if already booted)…"
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
open -a Simulator
# Give the simulator a moment to come up.
sleep 3

echo "==> Building HeadsUp.app for the simulator…"
DERIVED=$(mktemp -d)
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "id=$DEVICE_ID" \
    -derivedDataPath "$DERIVED" \
    build CODE_SIGNING_ALLOWED=NO \
    > /tmp/headsup-build.log 2>&1 || {
        echo "Build failed. Tail of /tmp/headsup-build.log:"
        tail -30 /tmp/headsup-build.log
        exit 1
    }

APP_PATH=$(find "$DERIVED/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name "*.app" | head -1)
if [ -z "$APP_PATH" ]; then
    echo "Couldn't find built .app under $DERIVED"
    exit 1
fi
echo "    built $APP_PATH"

echo "==> Installing on simulator…"
xcrun simctl install "$DEVICE_ID" "$APP_PATH"

echo "==> Launching app…"
BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Info.plist")
xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID"

# ── Capture loop ────────────────────────────────────────────────────────────

SHOTS=(
    "01-onboarding|Sign in with Apple page (the splash with Apple Sign In button)"
    "02-home|Agent list home (at least 1 agent + setup checklist visible)"
    "03-authorize|Authorize screen with the consent toggle visible"
    "04-detail|Agent detail: reply buttons + 一键已读 / 稍后再说 visible"
    "05-settings|Settings → Demo section visible"
)

for entry in "${SHOTS[@]}"; do
    name="${entry%%|*}"
    desc="${entry##*|}"
    echo
    echo "──────────────────────────────────────────────────────"
    echo "Screen $name"
    echo "  Navigate the simulator to: $desc"
    echo "  Then press [Enter] to capture →"
    read -r _ < /dev/tty
    OUT="$OUT_DIR/$name.png"
    xcrun simctl io "$DEVICE_ID" screenshot --type=png "$OUT"
    SIZE=$(file "$OUT" | sed -E 's/.*([0-9]+ x [0-9]+).*/\1/' || echo "?")
    echo "    saved: $OUT  ($SIZE)"
done

echo
echo "==> All 5 captured. Files:"
ls -la "$OUT_DIR"
echo
echo "Upload to App Store Connect → Version → iPhone 6.7\" Display."
