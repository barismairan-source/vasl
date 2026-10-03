#!/usr/bin/env python3
"""سرور لینک اشتراک (Subscription) و ریلی برای vasl.

مسیرها:
  GET  /sub/<token>                 برنامه‌ها: فهرست کانفیگ‌ها (base64) — مرورگر: صفحه‌ی فارسی با QR
  GET  /relay/<token>               اسکریپت نصب سرور ایران
  GET  /relay/<token>/xray.zip      فایل Xray برای سرور ایران (بدون نیاز به GitHub)
  POST /relay/<token>/register      سرور ایران لینک خودش را ثبت می‌کند
  GET  /static/<font>.woff2         فونت وزیرمتن (از خود سرور، بدون CDN)
کانفیگ‌ها هر بار از `vasl` ساخته می‌شوند، پس همیشه به‌روزند.
"""
import base64
import html
import json
import os
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 2096
VASL = "/usr/local/bin/vasl"
ASSETS = "/usr/local/lib/vasl/assets"
XRAY_ZIP = "/usr/local/share/vasl/xray.zip"
SUB_RE = re.compile(r"^/sub/([0-9a-f]{24})/?$")
QR_RE = re.compile(r"^/sub/([0-9a-f]{24})/qr/([0-9]{1,2})$")
CDNIPS_RE = re.compile(r"^/sub/([0-9a-f]{24})/cdn-ips$")
RELAY_RE = re.compile(r"^/relay/([0-9a-f]{24})(/xray\.zip|/register)?$")
FONTS = {"Vazirmatn-Regular.woff2", "Vazirmatn-Bold.woff2"}

# برچسب هر روش بر اساس انتهای نام کانفیگ (#vasl-<user>-<kind>)
KINDS = {
    "ssh": ("تونل SSH", "SSH", "وقتی فقط SSH باز است؛ در Hiddify و مک"),
    "relay": ("ریلی ایران", "Iran → DE", "اول این را امتحان کنید؛ گوشی فقط به سرور داخلی وصل می‌شود"),
    "vision": ("REALITY", "TCP", "روش اصلی؛ شبیه بازدید از یک سایت معمولی"),
    "hy2": ("Hysteria2", "UDP", "خیلی سریع؛ اگر اپراتور UDP را نبندد"),
    "tuic": ("TUIC", "UDP", "پشتیبان Hysteria2"),
    "cdn": ("Cloudflare", "CDN", "وقتی IP سرور فیلتر شد"),
    "xhttp": ("XHTTP", "TCP", "فقط در v2rayN و v2rayNG"),
    "cdnws": ("CDN دامنه‌ی شما", "WS", "از شبکه‌ی Cloudflare؛ در همه‌ی برنامه‌ها"),
    "cdnxh": ("CDN دامنه‌ی شما", "XHTTP", "از شبکه‌ی Cloudflare؛ v2rayNG و Streisand"),
}


def vasl(*args, data=None):
    try:
        r = subprocess.run([VASL, *args], capture_output=True, text=True, timeout=30, input=data)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None


def qr_svg(text):
    try:
        svg = subprocess.run(["qrencode", "-t", "SVG", "--svg-path", "-m", "1", "-o", "-", text],
                             capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    return svg[svg.find("<svg"):] if "<svg" in svg else ""


CSS = """
@font-face { font-family: Vazirmatn; src: url(/static/Vazirmatn-Regular.woff2) format("woff2"); font-weight: 400; font-display: swap; }
@font-face { font-family: Vazirmatn; src: url(/static/Vazirmatn-Bold.woff2) format("woff2"); font-weight: 700; font-display: swap; }
:root {
  --bg: #f4f5f7; --surface: #ffffff; --fg: #15171a; --muted: #5f6672; --line: #e3e6ea;
  --accent: #2f6fed; --accent-fg: #ffffff; --soft: #eaf0fe; --ok: #138a52;
}
@media (prefers-color-scheme: dark) {
  :root { --bg: #0f1114; --surface: #181b20; --fg: #eceef1; --muted: #9aa3ae; --line: #262a31;
          --accent: #5b8cff; --accent-fg: #0b0d10; --soft: #1c2536; --ok: #3ccf8e; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg);
       font: 16px/1.8 Vazirmatn, Tahoma, sans-serif; -webkit-text-size-adjust: 100%; }
main { max-width: 560px; margin: 0 auto; padding: 20px 16px 40px; }
header { display: flex; align-items: center; gap: 12px; margin-bottom: 8px; }
.logo { width: 44px; height: 44px; border-radius: 12px; background: var(--accent); color: var(--accent-fg);
        display: grid; place-items: center; font-weight: 700; font-size: 22px; }
h1 { font-size: 22px; margin: 0; } h2 { font-size: 17px; margin: 28px 0 10px; }
.sub { color: var(--muted); font-size: 14px; margin: 0; }
.card { background: var(--surface); border: 1px solid var(--line); border-radius: 16px; padding: 16px; margin: 12px 0; }
.btn { display: flex; align-items: center; justify-content: center; width: 100%; min-height: 48px; margin-top: 10px;
       border: 0; border-radius: 12px; background: var(--accent); color: var(--accent-fg); font: inherit; font-weight: 700;
       text-decoration: none; cursor: pointer; }
.btn.ghost { background: var(--soft); color: var(--accent); }
.mono { direction: ltr; text-align: left; font: 12px/1.6 ui-monospace, Menlo, Consolas, monospace; color: var(--muted);
        background: var(--bg); border-radius: 10px; padding: 10px; word-break: break-all; user-select: all; }
.qr { background: #fff; border-radius: 12px; padding: 10px; width: 220px; margin: 14px auto 0; }
.qr svg { display: block; width: 100%; height: auto; }
details > summary { list-style: none; cursor: pointer; display: flex; align-items: center; gap: 12px; }
details > summary::-webkit-details-marker { display: none; }
.num { flex: none; width: 32px; height: 32px; border-radius: 10px; background: var(--soft); color: var(--accent);
       display: grid; place-items: center; font-weight: 700; }
.meta { flex: 1; min-width: 0; } .meta b { display: block; } .meta span { color: var(--muted); font-size: 13px; }
.tag { flex: none; font-size: 12px; direction: ltr; color: var(--muted); border: 1px solid var(--line);
       border-radius: 999px; padding: 2px 10px; }
details[open] > summary { margin-bottom: 4px; }
ol { padding-inline-start: 20px; margin: 0; } li { margin: 4px 0; }
.note { color: var(--muted); font-size: 13px; }
"""

JS = """
function loadQr(d) {
  const q = d.querySelector('.qr[data-i]');
  if (!d.open || !q || q.dataset.done) return;
  q.dataset.done = 1; q.textContent = '…';
  fetch(location.pathname.replace(/\/$/, '') + '/qr/' + q.dataset.i).then(r => r.text()).then(t => q.innerHTML = t);
}
function cp(text, b) {
  const done = () => { const o = b.textContent; b.textContent = '✓ کپی شد'; setTimeout(() => b.textContent = o, 1500); };
  if (navigator.clipboard && window.isSecureContext) { navigator.clipboard.writeText(text).then(done); return; }
  const t = document.createElement('textarea'); t.value = text; document.body.appendChild(t); t.select();
  document.execCommand('copy'); t.remove(); done();
}
"""


SCANNER = """
<h2>پیدا کردن IP تمیز Cloudflare</h2>
<div class="card">
  <p class="note" style="margin:0 0 8px">اگر روش‌های CDN وصل نمی‌شوند، احتمالاً IPهای Cloudflare روی اینترنت شما فیلترند.
  <b>فیلترشکن را خاموش کنید</b> و دکمه را بزنید؛ این صفحه IPهای سالم را از اینترنت خود شما پیدا و در اشتراک ذخیره می‌کند.</p>
  <button class="btn" id="scanBtn" onclick="scan()">شروع اسکن</button>
  <p class="note" id="scanStatus" style="margin:10px 0 0"></p>
  <div id="scanResult"></div>
</div>
"""

SCANNER_JS = r"""
const CF = ['104.16.0.0/13','104.24.0.0/14','172.64.0.0/13','162.158.0.0/15','188.114.96.0/20','141.101.64.0/18',
  '108.162.192.0/18','173.245.48.0/20','190.93.240.0/20','198.41.128.0/17','197.234.240.0/22','103.21.244.0/22',
  '103.22.200.0/22','103.31.4.0/22','131.0.72.0/22'];
function rndIp() {
  const [base, bits] = CF[Math.floor(Math.random() * CF.length)].split('/');
  const b = base.split('.').reduce((a, o) => (a << 8) + +o, 0) >>> 0;
  const n = (b + Math.floor(Math.random() * 2 ** (32 - bits))) >>> 0;
  if ((n & 255) === 0 || (n & 255) === 255) return rndIp();
  return [n >>> 24, (n >> 16) & 255, (n >> 8) & 255, n & 255].join('.');
}
async function probe(ip) {
  const c = new AbortController(), t0 = performance.now(), tm = setTimeout(() => c.abort(), 2200);
  try { await fetch('https://' + ip + '/cdn-cgi/trace?' + Math.random(), {mode: 'no-cors', cache: 'no-store', signal: c.signal}); }
  catch (e) { if (c.signal.aborted) return null; }
  finally { clearTimeout(tm); }
  return Math.round(performance.now() - t0);
}
async function scan() {
  const btn = document.getElementById('scanBtn'), st = document.getElementById('scanStatus'), out = document.getElementById('scanResult');
  btn.disabled = true; out.innerHTML = '';
  const seen = new Set(), good = []; let tested = 0; const total = 240;
  const worker = async () => {
    while (tested < total && good.length < 12) {
      let ip; do { ip = rndIp(); } while (seen.has(ip)); seen.add(ip); tested++;
      const a = await probe(ip); if (a === null) continue;
      const b = await probe(ip); if (b === null) continue;
      good.push([ip, Math.min(a, b)]);
      st.textContent = `تست شد: ${tested} — سالم: ${good.length}`;
    }
  };
  st.textContent = 'در حال اسکن…';
  await Promise.all(Array.from({length: 6}, worker));
  good.sort((x, y) => x[1] - y[1]);
  if (!good.length) { st.textContent = `هیچ IP سالمی پیدا نشد (${tested} تست). اینترنت دیگری را امتحان کنید.`; btn.disabled = false; return; }
  const best = good.slice(0, 5).map(g => g[0]);
  out.innerHTML = '<div class="mono" style="margin-top:10px">' + good.slice(0, 8).map(g => `${g[0]}  —  ${g[1]}ms`).join('<br>') + '</div>';
  st.textContent = 'در حال ذخیره در اشتراک…';
  const r = await fetch(location.pathname.replace(/\/$/, '') + '/cdn-ips', {method: 'POST', body: JSON.stringify(best)});
  st.textContent = r.ok ? `✓ ${best.length} IP تمیز ذخیره شد. در برنامه «به‌روزرسانی اشتراک» را بزنید و روش‌های «IP تمیز» را امتحان کنید.`
                        : 'ذخیره ناموفق بود.';
  btn.disabled = false; btn.textContent = 'اسکن دوباره';
}
"""


def render_page(sub_url, links):
    cards = []
    for i, link in enumerate(links, 1):
        kind, _, ipn = link.rsplit("-", 1)[-1].partition("_ip")
        title, tag, desc = KINDS.get(kind, (kind, "", ""))
        if ipn:
            title, desc = f"{title} — IP تمیز {ipn}", "IPی که اسکنر از اینترنت خودتان پیدا کرده"
        esc = html.escape(link)
        cards.append(f"""
<details class="card" ontoggle="loadQr(this)">
  <summary><span class="num">{i}</span>
    <span class="meta"><b>{html.escape(title)}</b><span>{html.escape(desc)}</span></span>
    <span class="tag">{html.escape(tag)}</span></summary>
  <div class="qr" data-i="{i - 1}"></div>
  <div class="mono" style="margin-top:12px">{esc}</div>
  <button class="btn ghost" onclick='cp({html.escape(json.dumps(link))}, this)'>کپی این کانفیگ</button>
</details>""")
    s = html.escape(sub_url)
    scanner = SCANNER if any("-cdn" in l for l in links) else ""
    hiddify = html.escape("hiddify://import/" + sub_url + "#vasl")
    return f"""<!doctype html>
<html lang="fa" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>وصل</title><style>{CSS}</style></head>
<body><main>
<header><div class="logo">و</div><div><h1>وصل</h1><p class="sub">اتصال شخصی شما — {len(links)} روش در یک لینک</p></div></header>

<div class="card">
  <b>لینک اشتراک</b>
  <p class="note" style="margin:4px 0 10px">یک بار وارد برنامه کنید؛ همه‌ی روش‌ها با هم اضافه می‌شوند و خودکار به‌روز می‌شوند.</p>
  <div class="mono">{s}</div>
  <a class="btn" href="{hiddify}">افزودن به Hiddify</a>
  <button class="btn ghost" onclick='cp({html.escape(json.dumps(sub_url))}, this)'>کپی لینک اشتراک</button>
  <div class="qr">{qr_svg(sub_url)}</div>
</div>

<h2>راه‌اندازی</h2>
<div class="card"><ol>
  <li>برنامه را نصب کنید: <b>Hiddify</b> (همه‌ی سیستم‌ها)، <b>v2rayNG</b> (اندروید)، <b>Streisand</b> یا <b>Shadowrocket</b> (آیفون و مک).</li>
  <li>لینک اشتراک را کپی کنید و در برنامه «افزودن از کلیپ‌بورد» یا علامت <b>+</b> را بزنید.</li>
  <li>روش‌ها را به ترتیب شماره امتحان کنید. عدد پینگ کافی نیست؛ باید یک سایت واقعاً باز شود.</li>
  <li>اگر یک روش قطع شد، در برنامه «به‌روزرسانی اشتراک» را بزنید.</li>
</ol></div>

{scanner}
<h2>روش‌های اتصال</h2>
{''.join(cards)}
</main><script>{JS}{SCANNER_JS if scanner else ""}</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "nginx"
    sys_version = ""

    def send(self, code, body, ctype, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]

        if path.startswith("/static/"):
            name = path[len("/static/"):]
            if name in FONTS:
                with open(os.path.join(ASSETS, name), "rb") as f:
                    return self.send(200, f.read(), "font/woff2", {"Cache-Control": "max-age=2592000"})
            return self.send_error(404)

        m = QR_RE.match(path)
        if m:
            links = [l.strip() for l in (vasl("sub-links", m.group(1)) or "").splitlines() if "://" in l]
            i = int(m.group(2))
            return self.send(200, qr_svg(links[i]).encode(), "image/svg+xml") if i < len(links) else self.send_error(404)

        m = RELAY_RE.match(path)
        if m and m.group(2) != "/register":
            if m.group(2) == "/xray.zip":
                if vasl("relay-check", m.group(1)) is None or not os.path.exists(XRAY_ZIP):
                    return self.send_error(404)
                with open(XRAY_ZIP, "rb") as f:
                    return self.send(200, f.read(), "application/zip")
            script = vasl("relay-script", m.group(1))
            return self.send(200, script.encode(), "text/plain; charset=utf-8") if script else self.send_error(404)

        m = SUB_RE.match(path)
        out = vasl("sub-links", m.group(1)) if m else None
        links = [l.strip() for l in (out or "").splitlines() if "://" in l]
        if not links:
            return self.send_error(404)
        host = self.headers.get("Host") or f"localhost:{PORT}"
        sub_url = f"http://{host}/sub/{m.group(1)}"
        if "text/html" in self.headers.get("Accept", ""):
            return self.send(200, render_page(sub_url, links).encode(), "text/html; charset=utf-8")
        return self.send(200, base64.b64encode("\n".join(links).encode()), "text/plain; charset=utf-8", {
            "profile-title": "base64:" + base64.b64encode("vasl".encode()).decode(),
            "profile-update-interval": "1",
        })

    def do_POST(self):
        m = CDNIPS_RE.match(self.path.split("?")[0])
        if m:
            length = min(int(self.headers.get("Content-Length") or 0), 2048)
            try:
                ips = [str(i) for i in json.loads(self.rfile.read(length))][:5]
            except (ValueError, TypeError):
                return self.send_error(400)
            ok = vasl("cdn-ips", m.group(1), *ips) is not None
            return self.send(200 if ok else 400, b"ok\n" if ok else b"bad\n", "text/plain")
        m = RELAY_RE.match(self.path.split("?")[0])
        if not m or m.group(2) != "/register" or vasl("relay-check", m.group(1)) is None:
            return self.send_error(404)
        length = min(int(self.headers.get("Content-Length") or 0), 4096)
        link = self.rfile.read(length).decode(errors="replace").strip()
        ok = vasl("relay-add", link) is not None
        self.send(200 if ok else 400, b"ok\n" if ok else b"bad link\n", "text/plain")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
