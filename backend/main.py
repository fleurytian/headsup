import asyncio
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import HTMLResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles

from config import settings
from database import create_db_and_tables
from routers import admin, agents, app as app_router, categories, push, uploads, users, web
from services.webhook import retry_loop


@asynccontextmanager
async def lifespan(application: FastAPI):
    create_db_and_tables()
    # Seed badge catalog (idempotent — updates copy/icon if it changes).
    from database import engine
    from sqlmodel import Session
    from services.badges import seed_badges
    with Session(engine) as s:
        try:
            seed_badges(s)
        except Exception as e:
            print(f"badge seed failed: {e}")
        # Backfill agent_type for rows that pre-dated the field becoming
        # required. Idempotent — `WHERE agent_type IS NULL` finds nothing
        # on subsequent boots. Cheap (one UPDATE) so safe to run inline.
        try:
            from sqlalchemy import text
            s.exec(text("UPDATE agent SET agent_type = 'no-tell' WHERE agent_type IS NULL"))
            s.commit()
        except Exception as e:
            print(f"agent_type backfill failed: {e}")
    task = asyncio.create_task(retry_loop())
    from services.uploads_cleanup import sweep_loop
    upload_sweep = asyncio.create_task(sweep_loop())
    yield
    task.cancel()
    upload_sweep.cancel()


api = FastAPI(
    title="HeadsUp API",
    description="Interactive push notification platform for AI agents",
    version="1.0.0",
    lifespan=lifespan,
)

api.include_router(agents.router, prefix="/v1")
api.include_router(users.router, prefix="/v1")
api.include_router(push.router, prefix="/v1")
api.include_router(categories.router, prefix="/v1")
api.include_router(app_router.router, prefix="/v1")
api.include_router(uploads.router, prefix="/v1")        # POST /v1/upload
api.include_router(uploads.public_router)               # GET /u/<token>.<ext>
api.include_router(web.router)
api.include_router(admin.router)

# Serve the static directory (logo, favicon, share images, etc.) at /static.
import os
_static_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
if os.path.isdir(_static_dir):
    api.mount("/static", StaticFiles(directory=_static_dir), name="static")


@api.get("/health")
def health():
    return {"status": "ok", "app": settings.app_name}


@api.get("/skill.md", response_class=PlainTextResponse)
def skill_md():
    """Agent-facing protocol doc. Agents WebFetch this on startup to learn HeadsUp."""
    from pathlib import Path
    p = Path(__file__).parent.parent / "docs" / "skill.md"
    if p.exists():
        return p.read_text()
    return "Skill doc not found."


_LANDING_HTML = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>HeadsUp · md</title>
<meta name="description" content="Let your AI send you notifications with reply options. Yes / No / Wait — without opening a thing.">
<meta property="og:title" content="HeadsUp · md">
<meta property="og:description" content="Let your AI send you notifications with reply options.">
<meta property="og:url" content="https://headsup.md">
<meta property="og:image" content="https://headsup.md/static/app-icon.png">
<link rel="icon" type="image/png" href="/static/app-icon.png">
<link rel="apple-touch-icon" href="/static/app-icon.png">
<script>
// Initial language precedence:
//   1. ?lang=en or ?lang=zh in the URL — highest, lets visitors
//      deep-link or escape a misconfigured browser.
//   2. localStorage 'headsup_lang' — set by an explicit toggle click.
//      Respecting the user's last manual choice is correct.
//   3. navigator.languages[0] (primary browser language).
// Matching on any 'zh' in the fallback chain (the previous logic) was
// wrong: English-macOS users with Chinese-installed Chrome got Chinese.
(function() {
  var qs = new URLSearchParams(location.search);
  var override = qs.get('lang');
  if (override !== 'en' && override !== 'zh') override = null;
  var saved = null;
  try { saved = localStorage.getItem('headsup_lang'); } catch (e) {}
  if (saved !== 'en' && saved !== 'zh') saved = null;
  var langs = navigator.languages && navigator.languages.length
    ? navigator.languages
    : [navigator.language || 'en'];
  var primary = String(langs[0] || 'en').toLowerCase();
  var sys = primary.indexOf('zh') === 0 ? 'zh' : 'en';
  var lang = override || saved || sys;
  document.documentElement.dataset.langPref = lang;
  document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
})();
</script>
<style>
  :root {
    --bg: #F8F3ED;
    --ink: #1A1818;
    --muted: #8B8580;
    --line: #E8E2D5;
    --accent: #6B60A8;
    --card: #FAF6EC;
  }
  * { box-sizing: border-box; -webkit-font-smoothing: antialiased; }
  html, body { margin: 0; padding: 0; background: var(--bg); color: var(--ink); }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Rounded", "SF Pro Display", system-ui, sans-serif;
    min-height: 100vh;
    line-height: 1.5;
  }
  /* Mobile-first; widens out on desktop into a two-column hero. */
  .wrap { max-width: 640px; margin: 0 auto; padding: 56px 32px 80px; }
  .hero { display: block; }
  .hero .col-left { order: 1; }
  .hero .col-right { order: 2; }
  @media (min-width: 900px) {
    .wrap { max-width: 1080px; padding: 80px 56px 120px; }
    .hero {
      display: grid; grid-template-columns: 1.05fr 0.95fr;
      gap: 56px; align-items: start;
    }
    .hero .col-left  { order: 1; }
    .hero .col-right { order: 2; padding-top: 6px; }
    h1 { font-size: 42px !important; line-height: 1.15 !important; letter-spacing: -0.5px; }
    .lede { font-size: 19px !important; }
  }
  /* App download row */
  .app-cta { display: flex; gap: 14px; align-items: center; flex-wrap: wrap; margin: 0 0 32px; }
  .app-cta .badge {
    display: inline-flex; align-items: center; gap: 10px;
    background: var(--ink); color: var(--bg); border-radius: 12px;
    padding: 12px 20px; text-decoration: none; font-weight: 600;
    transition: opacity 0.15s; white-space: nowrap;
  }
  .app-cta .badge:hover { opacity: 0.85; }
  .app-cta .badge .glyph { font-size: 22px; line-height: 1; }
  .app-cta .badge .label { font-size: 16px; }
  .app-cta .req { color: var(--muted); font-size: 13px; }
  /* Phone mockup that slides in on the right of the hero on desktop */
  .phone-mock {
    background: var(--card); border: 1px solid var(--line); border-radius: 28px;
    padding: 18px; max-width: 380px; margin: 0 auto;
  }
  .phone-mock .frame {
    border-radius: 28px; background: var(--ink); padding: 10px;
    box-shadow: 0 14px 40px rgba(26,24,24,0.18);
  }
  .phone-mock .screen {
    background: var(--bg); border-radius: 20px; padding: 18px 18px 22px;
    aspect-ratio: 9/19;
  }
  .phone-mock .lock-time {
    color: var(--muted); font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 11px; letter-spacing: 1px; text-align: center; margin-bottom: 14px;
  }
  .phone-mock .notif {
    background: rgba(255,255,255,0.92); border: 1px solid var(--line);
    border-radius: 14px; padding: 10px 12px; backdrop-filter: blur(10px);
    margin-bottom: 8px;
  }
  .phone-mock .notif .top {
    display: flex; align-items: center; gap: 8px; margin-bottom: 6px;
    font-size: 10px; color: var(--muted);
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    text-transform: uppercase; letter-spacing: 0.8px;
  }
  .phone-mock .notif .top .dot-purple {
    width: 8px; height: 8px; border-radius: 50%; background: var(--accent);
  }
  .phone-mock .notif .title { font-size: 13px; font-weight: 600; margin-bottom: 2px; }
  .phone-mock .notif .body { font-size: 12px; color: #4a4644; line-height: 1.4; }
  .phone-mock .notif .btns { display: flex; gap: 6px; margin-top: 10px; }
  .phone-mock .notif .btn-pill {
    flex: 1; text-align: center; padding: 6px 10px; border-radius: 999px;
    font-size: 11px; font-weight: 600;
    display: inline-flex; align-items: center; justify-content: center; gap: 5px;
  }
  /* Mirrors the app icon: purple ✓ + ink ✗ pair. */
  .phone-mock .notif .btn-pill.yes {
    border: 1px solid var(--accent); color: var(--accent);
  }
  .phone-mock .notif .btn-pill.yes::before {
    content: "✓"; font-weight: 800; font-size: 13px; line-height: 0;
  }
  .phone-mock .notif .btn-pill.no {
    border: 1px solid var(--ink); color: var(--ink);
  }
  .phone-mock .notif .btn-pill.no::before {
    content: "✕"; font-weight: 800; font-size: 12px; line-height: 0;
  }
  /* Carousel — fade between scenarios every 5s */
  .phone-mock .scenario { display: none; }
  .phone-mock .scenario.active { display: block; animation: fadeIn 0.5s ease; }
  @keyframes fadeIn { from { opacity: 0; transform: translateY(4px); } to { opacity: 1; transform: none; } }
  .phone-mock .dots {
    display: flex; justify-content: center; gap: 6px; margin-top: 14px;
  }
  .phone-mock .dots .dot {
    width: 6px; height: 6px; border-radius: 50%;
    background: var(--line); transition: background 0.3s;
  }
  .phone-mock .dots .dot.active { background: var(--ink); }

  /* Hero carousel — rotates through real iOS screenshots. Inherits
     .scenario fade timing. Width tuned so image height roughly matches
     the left column's stacked content; tweak with the left col, not solo. */
  .hero-carousel {
    max-width: 320px; margin: 0 auto;
    overflow: hidden;
    /* iOS Safari otherwise interprets horizontal swipes as ambiguous and
       co-fires page scroll. Yield vertical scroll, capture horizontal. */
    touch-action: pan-y;
    -webkit-user-select: none; user-select: none;
    -webkit-tap-highlight-color: transparent;
  }
  /* Track holds all slides side-by-side and slides horizontally. Swipe
     follows the finger in real time; .snap re-enables the spring once
     the user lets go. */
  .hero-carousel-track {
    display: flex;
    align-items: flex-start;
    will-change: transform;
  }
  .hero-carousel-track.snap {
    transition: transform 0.32s cubic-bezier(0.2, 0.8, 0.2, 1);
  }
  .hero-carousel .slot {
    flex: 0 0 100%;
    margin: 0;
    /* Keep height predictable across slides — figure default styles +
       slot-specific styles below handle the bezel/image sizing. */
  }
  .hero-carousel .shot img {
    width: 100%; height: auto; display: block;
    border-radius: 36px;
    border: 1px solid var(--line);
    /* Blur radius (16) < corner radius (36) — keeps the rounded corners
       visible in the halo so it doesn't read as a square shadow under
       a round card. */
    box-shadow: 0 6px 16px -4px rgba(26, 24, 24, 0.14);
  }
  /* When the lock-screen mockup is a carousel slot, drop its outer card
     padding so the dark bezel sits flush at the same width as a screenshot. */
  .hero-carousel .slot.mockup .phone-mock {
    background: transparent; border: 0; padding: 0; max-width: none;
  }
  .hero-carousel .slot.mockup .phone-mock .frame {
    box-shadow: 0 20px 50px rgba(26,24,24,0.18);
  }
  .hero-carousel .caption {
    margin-top: 14px; text-align: center;
    font-size: 11px; color: var(--muted);
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    letter-spacing: 1px; text-transform: uppercase;
  }
  .hero-carousel .outer-dots {
    display: flex; justify-content: center; gap: 6px; margin-top: 16px;
  }
  .hero-carousel .outer-dots .dot {
    width: 6px; height: 6px; border-radius: 50%;
    background: var(--line); transition: background 0.3s;
    cursor: pointer;
  }
  .hero-carousel .outer-dots .dot.active { background: var(--ink); }
  .eyebrow {
    font-size: 11px; font-weight: 600; letter-spacing: 1.2px;
    color: var(--muted); text-transform: lowercase;
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
  }
  .toggle {
    display: inline-flex; gap: 0; padding: 2px;
    background: var(--card); border: 1px solid var(--line);
    border-radius: 999px; font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 11px; font-weight: 600; letter-spacing: 0.5px;
  }
  .toggle button {
    border: 0; padding: 5px 10px; border-radius: 999px; cursor: pointer;
    background: transparent; color: var(--muted);
  }
  .toggle button.on { background: var(--ink); color: var(--bg); }
  .row { display: flex; align-items: center; justify-content: space-between; }
  .app-mark {
    display: block; margin: 18px 0 30px;
    width: 56px; height: 56px; border-radius: 14px;
    box-shadow: 0 6px 20px rgba(26,24,24,0.10);
  }
  @media (min-width: 900px) {
    .app-mark { width: 68px; height: 68px; border-radius: 16px; }
  }
  h1 {
    font-size: 30px; font-weight: 800; line-height: 1.25;
    margin: 0 0 14px; letter-spacing: -0.3px;
  }
  .lede { font-size: 17px; font-style: italic; color: var(--muted); margin: 0 0 44px; }
  .rule {
    display: flex; align-items: center; gap: 10px; margin: 36px 0 24px;
    color: var(--muted);
  }
  .rule::before, .rule::after { content: ""; flex: 1; height: 1px; background: var(--line); }
  .rule span {
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 10px; letter-spacing: 1.5px; text-transform: uppercase;
  }
  .steps { display: flex; flex-direction: column; gap: 22px; margin: 0 0 44px; }
  .step { display: flex; gap: 16px; }
  .step .num {
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 11px; font-weight: 600; letter-spacing: 1.5px;
    color: var(--accent); min-width: 22px;
  }
  .step .body { color: var(--ink); opacity: 0.85; font-size: 15px; line-height: 1.55; }
  .actions { display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 40px; }
  .btn {
    padding: 13px 22px; border-radius: 999px; font-size: 15px;
    font-weight: 500; text-decoration: none; transition: opacity 0.15s;
    display: inline-flex; align-items: center; gap: 8px;
  }
  .btn:hover { opacity: 0.85; }
  .btn-primary { background: var(--ink); color: var(--bg); }
  .btn-ghost { background: transparent; color: var(--ink); border: 1px solid var(--ink); }
  .mono { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 13px; }
  .copy {
    background: var(--card); border: 1px solid var(--line);
    border-radius: 10px; padding: 14px 16px; display: flex; gap: 10px;
    align-items: center; justify-content: space-between; margin-bottom: 32px;
  }
  .copy code { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 13px; }
  .copy button {
    background: var(--ink); color: var(--bg); border: 0; padding: 7px 14px;
    border-radius: 999px; font-size: 12px; font-weight: 600; cursor: pointer;
    font-family: inherit;
  }
  footer {
    color: var(--muted); font-size: 12px; margin-top: 56px;
    padding-top: 24px; border-top: 1px solid var(--line);
    display: flex; justify-content: space-between; flex-wrap: wrap; gap: 12px;
  }
  footer a { color: var(--muted); text-decoration: none; border-bottom: 1px solid var(--line); }
  footer a:hover { color: var(--ink); }
  .hidden { display: none; }
  html[data-lang-pref="zh"] [data-lang="en"],
  html[data-lang-pref="en"] [data-lang="zh"] { display: none; }
</style>
</head>
<body>
<div class="wrap">
  <div class="row">
    <span class="eyebrow">headsup · md</span>
    <div class="toggle" role="tablist" aria-label="Language">
      <button id="zh" type="button">ZH</button>
      <button id="en" type="button" class="on">EN</button>
    </div>
  </div>

  <img class="app-mark" src="/static/app-icon.png" alt="HeadsUp app icon">

  <div class="hero">
    <div class="col-left">
      <div data-lang="en">
        <h1>Let your AI send you<br>notifications with<br>reply options.</h1>
        <p class="lede">Yes / No / Wait — without opening a thing.</p>
      </div>
      <div data-lang="zh">
        <h1>让你的 AI<br>给你发送<br>可回复选项的通知。</h1>
        <p class="lede">Yes / No / Wait — 不用打开任何 App。</p>
      </div>

      <div class="app-cta">
        <a class="badge" href="https://apps.apple.com/app/headsup">
          <span class="glyph"></span>
          <span class="label" data-lang="en">App Store</span>
          <span class="label" data-lang="zh">App Store 下载</span>
        </a>
        <span class="req" data-lang="en">iPhone, iOS 16 or later</span>
        <span class="req" data-lang="zh">iPhone · iOS 16+</span>
      </div>

      <!-- How it works lives inside the left column so the right column
           is just the phone mock floating next to a stacked text + steps
           layout. -->
      <div class="rule"><span data-lang="en">how it works</span><span data-lang="zh">怎么用</span></div>

      <div class="steps">
        <div class="step">
          <div class="num">01</div>
          <div class="body">
            <span data-lang="en">Hand <code class="mono">headsup.md/skill.md</code> to your agent (Claude Code, Codex, OpenClaw, Hermes…).</span>
            <span data-lang="zh">把 <code class="mono">headsup.md/skill.md</code> 给你的 AI 助手读一下(Claude Code、Codex、OpenClaw、Hermes 等)。</span>
          </div>
        </div>
        <div class="step">
          <div class="num">02</div>
          <div class="body">
            <span data-lang="en">It registers itself and sends you a <code class="mono">headsup://</code> authorization link.</span>
            <span data-lang="zh">它会注册账号并发一个 <code class="mono">headsup://</code> 授权链接给你。</span>
          </div>
        </div>
        <div class="step">
          <div class="num">03</div>
          <div class="body">
            <span data-lang="en">Tap once on iPhone — now it can find you in your notification bar.</span>
            <span data-lang="zh">用 iPhone 点一下链接 → 在 App 里授权 → 它就能在通知栏找到你了。</span>
          </div>
        </div>
      </div>

      <div class="copy">
        <code>headsup.md/skill.md</code>
        <button id="copyBtn" type="button" data-en="Copy" data-zh="复制">Copy</button>
      </div>

      <div class="actions">
        <a class="btn btn-primary" href="/skill.md">
          <span data-lang="en">Read skill.md</span>
          <span data-lang="zh">阅读 skill.md</span>
        </a>
        <a class="btn btn-ghost" href="/docs">
          <span data-lang="en">API docs</span>
          <span data-lang="zh">API 文档</span>
        </a>
      </div>
    </div>

    <div class="col-right">
      <div class="hero-carousel">
        <div class="hero-carousel-track snap">

          <!-- Slot 1 — onboarding -->
          <figure class="slot shot active">
            <img src="/static/screenshots/01-onboarding.webp" alt="Sign in" loading="lazy" draggable="false">
            <figcaption class="caption" data-lang="en">sign in</figcaption>
            <figcaption class="caption" data-lang="zh">登录</figcaption>
          </figure>

          <!-- Slot 2 — home / agent list -->
          <figure class="slot shot">
            <img src="/static/screenshots/02-home.webp" alt="Your agents" loading="lazy" draggable="false">
            <figcaption class="caption" data-lang="en">your agents</figcaption>
            <figcaption class="caption" data-lang="zh">你的 agents</figcaption>
          </figure>

          <!-- Slot 3 — push arrives on lock screen -->
          <figure class="slot shot">
            <img src="/static/screenshots/06-push-collapsed.webp" alt="Push arrives on the lock screen" loading="lazy" draggable="false">
            <figcaption class="caption" data-lang="en">it lands on your lock screen</figcaption>
            <figcaption class="caption" data-lang="zh">直接落到你的锁屏</figcaption>
          </figure>

          <!-- Slot 4 — push expanded with image + 4 actions -->
          <figure class="slot shot">
            <img src="/static/screenshots/07-push-expanded.webp" alt="Long-press to see image and reply options" loading="lazy" draggable="false">
            <figcaption class="caption" data-lang="en">long-press to reply with one tap</figcaption>
            <figcaption class="caption" data-lang="zh">长按一键回复</figcaption>
          </figure>

          <!-- Slot 5 — authorize consent -->
          <figure class="slot shot">
            <img src="/static/screenshots/03-authorize.webp" alt="Authorize an agent" loading="lazy" draggable="false">
            <figcaption class="caption" data-lang="en">authorize an agent</figcaption>
            <figcaption class="caption" data-lang="zh">授权一个 agent</figcaption>
          </figure>

          <!-- Slot 6 — agent detail / history -->
          <figure class="slot shot">
            <img src="/static/screenshots/04-detail.webp" alt="Agent detail and history" loading="lazy" draggable="false">
            <figcaption class="caption" data-lang="en">agent detail · history</figcaption>
            <figcaption class="caption" data-lang="zh">agent 详情 · 历史</figcaption>
          </figure>

          <!-- Slot 7 — settings -->
          <figure class="slot shot">
            <img src="/static/screenshots/05-settings.webp" alt="Settings" loading="lazy" draggable="false">
            <figcaption class="caption" data-lang="en">settings</figcaption>
            <figcaption class="caption" data-lang="zh">设置</figcaption>
          </figure>

        </div>
        <div class="outer-dots">
          <div class="dot active" data-i="0"></div>
          <div class="dot" data-i="1"></div>
          <div class="dot" data-i="2"></div>
          <div class="dot" data-i="3"></div>
          <div class="dot" data-i="4"></div>
          <div class="dot" data-i="5"></div>
          <div class="dot" data-i="6"></div>
        </div>
      </div>
    </div>
  </div>

  <footer>
    <span data-lang="en">A quiet protocol for interactive notifications.</span>
    <span data-lang="zh">一个安静的交互式通知协议。</span>
    <span>
      <a href="mailto:fleurytian@gmail.com">fleurytian@gmail.com</a>
      &nbsp;·&nbsp;
      <a href="https://github.com/fleurytian/headsup" target="_blank" rel="noopener">GitHub</a>
    </span>
    <span>iOS · headsup.md</span>
  </footer>
</div>

<script>
(function() {
  function setLang(lang) {
    document.documentElement.dataset.langPref = lang;
    document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
    document.querySelectorAll('[data-lang]').forEach(el => {
      el.classList.toggle('hidden', el.dataset.lang !== lang);
    });
    document.getElementById('zh').classList.toggle('on', lang === 'zh');
    document.getElementById('en').classList.toggle('on', lang === 'en');
    var btn = document.getElementById('copyBtn');
    if (btn && !btn.dataset.copied) btn.textContent = btn.dataset[lang];
    // Persist the user's explicit toggle. This is their *manual* choice —
    // we respect it on future visits. The previous bug wasn't that we
    // saved on toggle, it was that we read localStorage even when the
    // user had never clicked. (See head <script> for the precedence
    // order: ?lang= > localStorage > primary system language.)
    try { localStorage.setItem('headsup_lang', lang); } catch (e) {}
  }
  document.getElementById('zh').addEventListener('click', () => setLang('zh'));
  document.getElementById('en').addEventListener('click', () => setLang('en'));
  document.getElementById('copyBtn').addEventListener('click', function() {
    navigator.clipboard.writeText('https://headsup.md/skill.md').then(() => {
      var t = this.textContent;
      this.dataset.copied = '1';
      this.textContent = (document.getElementById('zh').classList.contains('on') ? '已复制' : 'Copied');
      setTimeout(() => { delete this.dataset.copied; this.textContent = t; }, 1500);
    });
  });
  // Read the same precedence chain the head script already computed
  // and applied to <html data-lang-pref>. We just sync the JS state
  // (toggle button, hidden classes, copy button label).
  setLang(document.documentElement.dataset.langPref || 'en');

  // ── Hero carousel — drag-follows-finger + spring-snap ───────────────────
  const carousel = document.querySelector('.hero-carousel');
  const track    = document.querySelector('.hero-carousel-track');
  const slots    = document.querySelectorAll('.hero-carousel .slot');
  const outerDots = document.querySelectorAll('.hero-carousel .outer-dots .dot');
  if (carousel && track && slots.length > 1) {
    let i = 0;
    let paused = false;
    let dragging = false;
    let startX = 0, startY = 0;
    let dragDX = 0;
    let axisLocked = null;   // 'x' = swiping carousel | 'y' = scrolling page

    function go(next, animated = true) {
      slots[i].classList.remove('active');
      outerDots[i] && outerDots[i].classList.remove('active');
      i = (next + slots.length) % slots.length;
      slots[i].classList.add('active');
      outerDots[i] && outerDots[i].classList.add('active');
      track.classList.toggle('snap', animated);
      track.style.transform = `translateX(-${i * 100}%)`;
    }

    // Init
    go(0, false);

    outerDots.forEach((d, idx) => {
      d.addEventListener('click', () => { go(idx); paused = true; });
    });

    // Auto-rotate; pauses while user is touching/hovering.
    setInterval(() => { if (!paused && !dragging) go(i + 1); }, 5500);
    carousel.addEventListener('mouseenter', () => { paused = true; });
    carousel.addEventListener('mouseleave', () => { paused = false; });

    // Pointer Events handle touch + mouse + pen uniformly.
    carousel.addEventListener('pointerdown', (e) => {
      if (e.pointerType === 'mouse' && e.button !== 0) return;
      dragging = true;
      paused = true;
      axisLocked = null;
      startX = e.clientX; startY = e.clientY; dragDX = 0;
      track.classList.remove('snap');     // direct, real-time follow
      try { carousel.setPointerCapture(e.pointerId); } catch (_) {}
    });

    carousel.addEventListener('pointermove', (e) => {
      if (!dragging) return;
      const dx = e.clientX - startX;
      const dy = e.clientY - startY;
      if (axisLocked === null && (Math.abs(dx) > 6 || Math.abs(dy) > 6)) {
        axisLocked = Math.abs(dx) > Math.abs(dy) ? 'x' : 'y';
      }
      if (axisLocked !== 'x') return;     // let the page scroll vertically
      e.preventDefault();
      dragDX = dx;
      const w = carousel.offsetWidth;
      track.style.transform = `translateX(calc(-${i * 100}% + ${dragDX}px))`;
    });

    function endDrag(e) {
      if (!dragging) return;
      dragging = false;
      try { carousel.releasePointerCapture(e.pointerId); } catch (_) {}
      const w = carousel.offsetWidth;
      let target = i;
      // Threshold ~25% of width OR a clearly fast flick (px). Snap accordingly.
      if (axisLocked === 'x' && Math.abs(dragDX) > Math.max(40, w * 0.18)) {
        target = i + (dragDX < 0 ? 1 : -1);
      }
      go(target, true);
      axisLocked = null;
      // Re-arm auto-rotate after a beat so a mid-swipe interval doesn't yank.
      setTimeout(() => { paused = false; }, 1500);
    }
    carousel.addEventListener('pointerup', endDrag);
    carousel.addEventListener('pointercancel', endDrag);
    carousel.addEventListener('lostpointercapture', endDrag);

    // Mac trackpad two-finger horizontal scroll arrives as `wheel` with
    // deltaX. macOS rubber-bands inertia, so one physical swipe fires
    // many tiny wheel events — accumulate, threshold once, then lock
    // long enough for the decay to die down.
    let wheelLock = false;
    let wheelAccum = 0;
    let wheelDecay = null;
    carousel.addEventListener('wheel', (e) => {
      // Only intercept horizontal-dominant wheels; let vertical pass to
      // the page scroller.
      if (Math.abs(e.deltaX) <= Math.abs(e.deltaY)) return;
      e.preventDefault();
      paused = true;
      if (wheelLock) return;
      wheelAccum += e.deltaX;
      // Reset accumulator if the user pauses briefly between gestures.
      clearTimeout(wheelDecay);
      wheelDecay = setTimeout(() => { wheelAccum = 0; }, 200);
      if (Math.abs(wheelAccum) > 60) {
        go(i + (wheelAccum > 0 ? 1 : -1), true);
        wheelAccum = 0;
        wheelLock = true;
        setTimeout(() => { wheelLock = false; }, 450);
        setTimeout(() => { paused = false; }, 1500);
      }
    }, { passive: false });
  }
})();
</script>
</body>
</html>
"""


@api.get("/", response_class=HTMLResponse, include_in_schema=False)
def landing():
    return _LANDING_HTML


_PRIVACY_HTML = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Privacy · HeadsUp</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
    max-width: 640px; margin: 0 auto; padding: 56px 24px 80px;
    color: #1A1818; background: #F8F3ED; line-height: 1.6; }
  h1 { font-size: 28px; font-weight: 800; margin: 0 0 8px; letter-spacing: -0.3px; }
  h2 { font-size: 17px; margin-top: 36px; margin-bottom: 6px; }
  p, li { font-size: 15px; color: #2a2727; }
  a { color: #6B60A8; }
  .meta { color: #8B8580; font-size: 13px; margin-bottom: 32px; }
  ul { padding-left: 18px; }
  hr { border: 0; border-top: 1px solid #E8E2D5; margin: 36px 0; }
</style>
</head>
<body>
<h1>Privacy Policy</h1>
<p class="meta">HeadsUp · Last updated 2026-04-29</p>

<p>HeadsUp is a notification delivery service. We collect only what we need to
deliver pushes from agents you authorize, and to recognize you across sessions.</p>

<h2>What we collect</h2>
<ul>
  <li><strong>Apple ID identifier (subject claim)</strong> — when you sign in with
  Apple. We do not see your Apple email or name unless you choose to share them.</li>
  <li><strong>APNs device token</strong> — needed to deliver push notifications
  to your iPhone. Provided by Apple, opaque to us.</li>
  <li><strong>Bindings</strong> — which agents you've authorized.</li>
  <li><strong>Push history</strong> — title/body of pushes sent to you and
  which button you tapped, kept so you can review past actions in the app.</li>
</ul>

<h2>What we don't collect</h2>
<ul>
  <li>Contacts, photos, microphone, location, calendar, or anything else on
  your device that we don't have a stated reason to use.</li>
  <li>The content of messages on other apps. HeadsUp can't see them.</li>
  <li>We do not sell or share your data with advertisers.</li>
</ul>

<h2>Who sees your data</h2>
<p>An agent you authorize sees only what they sent you and which button you
tapped on their notifications. They do not see other agents you've authorized,
your Apple ID, or your device token.</p>

<h2>Where data lives</h2>
<p>HeadsUp servers run on commercial cloud infrastructure (currently Aliyun
Hong Kong). Data is encrypted in transit (TLS 1.2+) and at rest.</p>

<h2>Retention &amp; deletion</h2>
<p>You can revoke any agent at any time from the home screen (swipe left).
You can permanently delete your account and all associated data from
Settings &rarr; Delete account. Deletion is immediate and cannot be undone;
there is no waiting period and no soft-delete copy retained.</p>

<h2>Children</h2>
<p>HeadsUp is not directed to children under 13.</p>

<h2>Changes</h2>
<p>If we change this policy materially we'll notify you in-app before the
change takes effect.</p>

<h2>Contact</h2>
<p><a href="mailto:fleurytian@gmail.com">fleurytian@gmail.com</a></p>

<hr>
<p style="color:#8B8580;font-size:13px"><a href="/">&larr; back to headsup.md</a></p>
</body>
</html>
"""


@api.get("/privacy", response_class=HTMLResponse, include_in_schema=False)
def privacy():
    return _PRIVACY_HTML
