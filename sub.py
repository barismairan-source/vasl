#!/usr/bin/env python3
"""سرور لینک اشتراک (Subscription) برای vasl.

- برنامه‌های VPN (Hiddify، v2rayNG، Streisand و…) فهرست کانفیگ‌ها را به صورت base64 می‌گیرند.
- مرورگر یک صفحه‌ی فارسی با QR Code و دکمه‌ی کپی می‌بیند.
کانفیگ‌ها هر بار از `vasl sub-links <token>` ساخته می‌شوند، پس همیشه به‌روزند
(مثلاً وقتی آدرس تونل Cloudflare عوض می‌شود).
"""
import base64
import html
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 2096
TOKEN_RE = re.compile(r"^/sub/([0-9a-f]{24})/?$")

DESCRIPTIONS = {
    "vision": ("REALITY (TCP)", "روش اصلی؛ سریع و شبیه یک سایت معمولی"),
    "hy2": ("Hysteria2 (UDP)", "خیلی سریع؛ روی اینترنت‌هایی که UDP را نمی‌بندند"),
    "tuic": ("TUIC (UDP)", "پشتیبان Hysteria2"),
    "cdn": ("Cloudflare CDN", "وقتی IP سرور فیلتر شد، از شبکه‌ی Cloudflare رد می‌شود"),
    "xhttp": ("XHTTP + REALITY", "مخصوص v2rayN/v2rayNG؛ پشتیبان روش اصلی"),
}


def get_links(token):
    r = subprocess.run(["/usr/local/bin/vasl", "sub-links", token], capture_output=True, text=True, timeout=20)
    if r.returncode != 0:
        return None
    return [l.strip() for l in r.stdout.splitlines() if "://" in l]


def qr_svg(text):
    try:
        svg = subprocess.run(["qrencode", "-t", "SVG", "--svg-path", "-m", "1", "-o", "-", text],
                             capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    return svg[svg.find("<svg"):] if "<svg" in svg else ""


def render_page(sub_url, links):
    cards = []
    for i, link in enumerate(links):
        kind = link.rsplit("-", 1)[-1]
        title, desc = DESCRIPTIONS.get(kind, (kind, ""))
        cards.append(f"""
        <details class="card">
          <summary><b>{i + 1}. {html.escape(title)}</b><span>{html.escape(desc)}</span></summary>
          <div class="qr">{qr_svg(link)}</div>
          <textarea readonly id="l{i}">{html.escape(link)}</textarea>
          <button onclick="cp('l{i}', this)">کپی کانفیگ</button>
        </details>""")
    hiddify = "hiddify://import/" + sub_url + "#vasl"
    return f"""<!doctype html><html lang="fa" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>vasl</title>
<style>
:root {{ --bg:#f5f6f8; --fg:#1d1f23; --card:#fff; --muted:#666; --accent:#2563eb; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#111317; --fg:#e8e8e8; --card:#1b1e24; --muted:#9aa; --accent:#5b8cff; }} }}
body {{ margin:0; font-family:Vazirmatn,Tahoma,sans-serif; background:var(--bg); color:var(--fg); }}
main {{ max-width:560px; margin:auto; padding:16px; }}
h1 {{ font-size:1.4rem; }} p {{ color:var(--muted); line-height:1.8; }}
.card {{ background:var(--card); border-radius:12px; padding:12px 14px; margin:10px 0; }}
summary {{ cursor:pointer; display:flex; flex-direction:column; gap:4px; }}
summary span {{ color:var(--muted); font-size:.9rem; }}
.qr svg {{ width:100%; max-width:260px; display:block; margin:12px auto; background:#fff; border-radius:8px; }}
textarea {{ width:100%; box-sizing:border-box; height:70px; direction:ltr; font-size:.75rem; border-radius:8px; padding:6px; }}
button, a.btn {{ display:block; width:100%; box-sizing:border-box; text-align:center; margin-top:8px; padding:12px; border:0;
  border-radius:10px; background:var(--accent); color:#fff; font:inherit; text-decoration:none; cursor:pointer; }}
</style></head><body><main>
<h1>🔐 وصل</h1>
<p>این لینک اشتراک همه‌ی روش‌های اتصال را با هم دارد. برنامه خودش بهترین را انتخاب می‌کند و اگر یک روش فیلتر شد، بقیه کار می‌کنند.</p>
<div class="card">
  <b>لینک اشتراک</b>
  <textarea readonly id="sub">{html.escape(sub_url)}</textarea>
  <button onclick="cp('sub', this)">کپی لینک اشتراک</button>
  <a class="btn" href="{html.escape(hiddify)}">افزودن مستقیم به Hiddify</a>
  <div class="qr">{qr_svg(sub_url)}</div>
</div>
<p>یا هر روش را جداگانه اضافه کنید:</p>
{''.join(cards)}
<p>برنامه‌ها: Hiddify (همه‌ی سیستم‌ها)، v2rayNG (اندروید)، Streisand یا V2Box (iOS)، v2rayN (ویندوز و مک).</p>
</main>
<script>
function cp(id, b) {{
  const t = document.getElementById(id); t.select();
  (navigator.clipboard ? navigator.clipboard.writeText(t.value) : Promise.reject()).catch(() => document.execCommand('copy'));
  const o = b.textContent; b.textContent = '✅ کپی شد'; setTimeout(() => b.textContent = o, 1500);
}}
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "nginx"
    sys_version = ""

    def do_GET(self):
        m = TOKEN_RE.match(self.path.split("?")[0])
        links = get_links(m.group(1)) if m else None
        if not links:
            self.send_error(404)
            return
        host = self.headers.get("Host") or f"localhost:{PORT}"
        sub_url = f"http://{host}/sub/{m.group(1)}"
        if "text/html" in self.headers.get("Accept", ""):
            body = render_page(sub_url, links).encode()
            ctype = "text/html; charset=utf-8"
        else:
            body = base64.b64encode("\n".join(links).encode())
            ctype = "text/plain; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("profile-title", "base64:" + base64.b64encode("vasl".encode()).decode())
        self.send_header("profile-update-interval", "1")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
