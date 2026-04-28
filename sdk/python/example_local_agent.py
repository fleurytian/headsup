"""Example: a local agent (Hermes / Claude Code style) using HeadsUp.

This is what an agent's code looks like when it wants to ask the user.

Usage:
    cd sdk/python
    python3 example_local_agent.py
"""
import os
import sys

# So this runs from the repo without a pip install
sys.path.insert(0, os.path.dirname(__file__))

from headsup import HeadsUp


def main():
    # ── Setup (one-time, agent does this itself) ────────────────────────────
    bot = HeadsUp(
        api_key=os.environ.get("HEADSUP_API_KEY", "pk_S3hu_S4PCbDVnwhiM-lpoqmHfrDRcmzk6lwGYsR2u70"),
        base_url=os.environ.get("HEADSUP_BASE_URL", "http://localhost:8000"),
    )

    me = bot.me()
    print(f"✓ Authenticated as agent '{me['name']}' (id: {me['id'][:8]}...)")

    users = bot.users()
    if not users:
        print(f"\n⚠️  No users have authorized you yet.")
        print(f"   Send them this link: {bot.auth_link}")
        return
    user_key = users[0]["user_key"]
    print(f"✓ Will ask user {user_key}\n")

    # ── Define a custom button category (also one-time-ish) ─────────────────
    try:
        bot.create_category("travel_decision", buttons=[
            {"id": "book", "label": "立即预订", "icon": "checkmark.circle.fill"},
            {"id": "search_more", "label": "再看几个", "icon": "magnifyingglass"},
            {"id": "skip", "label": "算了", "icon": "xmark"},
        ])
        print("✓ Created custom category 'travel_decision'")
    except Exception as e:
        if "already exists" in str(e):
            print("· Category 'travel_decision' already exists, reusing")
        else:
            raise

    # ── The actual ask: send + wait + react ─────────────────────────────────
    print("\n📤 Asking user...")
    response = bot.ask(
        user_key=user_key,
        category="travel_decision",
        title="✈️  机票推荐",
        body="找到 4/30 上海→东京 直飞 ¥1899，要订吗？",
        data={"flight_id": "MU747", "price": 1899},
        timeout=90,
    )

    if response is None:
        print("\n⏱  Timeout — user didn't respond in 90s")
        return

    print(f"\n📨 User responded: {response['button_id']} ({response['button_label']})")
    print(f"   Original data echoed back: {response['data']}\n")

    # ── React to user's choice ──────────────────────────────────────────────
    if response["button_id"] == "book":
        print("→ Agent: booking flight MU747...")
    elif response["button_id"] == "search_more":
        print("→ Agent: searching more options...")
    else:
        print("→ Agent: skipping, asking next question or stopping...")


if __name__ == "__main__":
    main()
