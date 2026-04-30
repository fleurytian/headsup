import asyncio
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import HTMLResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles

from config import settings
from database import create_db_and_tables
from routers import admin, agents, app as app_router, categories, push, users, web
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
    task = asyncio.create_task(retry_loop())
    yield
    task.cancel()


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
api.include_router(web.router)
api.include_router(admin.router)


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
<meta name="description" content="Let your agents give you a heads up by reading skill.md. Yes / No / Wait — without opening a thing.">
<meta property="og:title" content="HeadsUp · md">
<meta property="og:description" content="Let your agents give you a heads up by reading skill.md.">
<meta property="og:url" content="https://headsup.md">
<script>
// Always derive initial language from the visitor's system preference.
// Previously we honored localStorage above system pref, but a user
// whose first visit was from a default-EN browser saw EN locked even
// after switching their OS to Chinese. The toggle still works during
// the session; we just don't persist it across visits.
(function() {
  var langs = navigator.languages && navigator.languages.length
    ? navigator.languages
    : [navigator.language || 'en'];
  var system = langs.some(function(l) {
    return String(l || '').toLowerCase().indexOf('zh') === 0;
  }) ? 'zh' : 'en';
  document.documentElement.dataset.langPref = system;
  document.documentElement.lang = system === 'zh' ? 'zh-CN' : 'en';
})();
</script>
<style>
  :root {
    --bg: #FFFDF8;
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
    border: 1px solid var(--ink); font-size: 11px; font-weight: 600;
  }
  .phone-mock .notif .btn-pill.alt {
    border-color: var(--line); color: var(--muted); font-weight: 500;
  }
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
  .dot { width: 18px; height: 18px; border-radius: 50%; background: var(--accent); margin: 14px 0 30px; }
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

  <div class="dot" aria-hidden="true"></div>

  <div class="hero">
    <div class="col-left">
      <div data-lang="en">
        <h1>Let your agents<br>give you a heads up<br>by reading <span style="color:var(--accent)">skill.md</span>.</h1>
        <p class="lede">Yes / No / Wait — without opening a thing.</p>
      </div>
      <div data-lang="zh">
        <h1>让你的 AI<br>通过读 <span style="color:var(--accent)">skill.md</span><br>来给你提个醒。</h1>
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
      <div class="phone-mock" aria-hidden="true">
        <div class="frame">
          <div class="screen">
            <div class="lock-time">9:41</div>
            <div class="notif">
              <div class="top"><span class="dot-purple"></span> CLAUDE CODE · NOW</div>
              <div class="title" data-lang="en">Deploy to prod?</div>
              <div class="title" data-lang="zh">上线到生产?</div>
              <div class="body" data-lang="en">build #4287 · 12 commits ahead. Looks clean. (long-press to reply)</div>
              <div class="body" data-lang="zh">build #4287 · 比线上多 12 个 commit,看着没问题。(长按回复)</div>
              <div class="btns">
                <div class="btn-pill" data-lang="en">Ship it</div>
                <div class="btn-pill" data-lang="zh">上线</div>
                <div class="btn-pill alt" data-lang="en">Wait</div>
                <div class="btn-pill alt" data-lang="zh">等等</div>
              </div>
            </div>
            <div class="notif">
              <div class="top"><span class="dot-purple" style="background:#D97757"></span> HERMES · 5 min ago</div>
              <div class="title" data-lang="en">Reservation confirmed.</div>
              <div class="title" data-lang="zh">预定确认。</div>
              <div class="body" data-lang="en">Sushi Yasuda, 7:30pm, 4 pax.</div>
              <div class="body" data-lang="zh">Sushi Yasuda 周五 7:30, 4 位。</div>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>

  <footer>
    <span data-lang="en">A quiet protocol for interactive notifications.</span>
    <span data-lang="zh">一个安静的交互式通知协议。</span>
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
  var saved = null;
  try { saved = localStorage.getItem('headsup_lang'); } catch (e) {}
  var langs = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language || 'en'];
  var system = langs.some(function(l) { return String(l || '').toLowerCase().indexOf('zh') === 0; }) ? 'zh' : 'en';
  var initial = saved || system;
  setLang(initial);
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
    color: #1A1818; background: #FFFDF8; line-height: 1.6; }
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
