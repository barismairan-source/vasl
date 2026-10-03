#!/usr/bin/env bash
# نصب خودکار VPN شخصی با Xray-core (VLESS + REALITY)
#
# دو پروفایل ساخته می‌شود:
#   1) VLESS + XTLS-Vision + REALITY روی TCP  (پورت پیش‌فرض 443)  — سریع‌ترین
#   2) VLESS + XHTTP + REALITY                  (پورت پیش‌فرض 8443) — پشتیبان، وقتی Vision اذیت شد
#
# استفاده:
#   sudo bash install.sh                 # نصب
#   sudo bash install.sh --reinstall     # ساخت دوباره‌ی کلیدها (کانفیگ‌های قبلی از کار می‌افتند)
#
# متغیرهای قابل تنظیم (قبل از اجرا export کنید):
#   SNI=www.microsoft.com  VISION_PORT=443  XHTTP_PORT=8443  FIRST_USER=user1  SKIP_FIREWALL=0

set -euo pipefail

SNI="${SNI:-www.microsoft.com}"
VISION_PORT="${VISION_PORT:-443}"
XHTTP_PORT="${XHTTP_PORT:-8443}"
FIRST_USER="${FIRST_USER:-user1}"
SKIP_FIREWALL="${SKIP_FIREWALL:-0}"

XRAY_DIR=/usr/local/etc/xray
CONFIG="$XRAY_DIR/config.json"
STATE="$XRAY_DIR/vasl.env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "این اسکریپت باید با root اجرا شود: sudo bash install.sh"
command -v apt-get >/dev/null || die "فعلاً فقط Ubuntu/Debian پشتیبانی می‌شود."
[[ -f "$SCRIPT_DIR/vasl.sh" && -f "$SCRIPT_DIR/sub.py" ]] || die "فایل‌های vasl.sh و sub.py کنار install.sh پیدا نشدند."

REINSTALL=0
[[ "${1:-}" == "--reinstall" ]] && REINSTALL=1

info "نصب پیش‌نیازها..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl jq openssl qrencode ca-certificates unzip >/dev/null

info "نصب / به‌روزرسانی Xray-core از مخزن رسمی XTLS..."
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
XRAY=/usr/local/bin/xray
"$XRAY" version | head -1

install -m 0755 "$SCRIPT_DIR/vasl.sh" /usr/local/bin/vasl
install -D -m 0755 "$SCRIPT_DIR/sub.py" /usr/local/lib/vasl/sub.py

# بعد از نصب پایه، پروتکل‌های اضافه و لینک اشتراک را راه می‌اندازد
finish() {
    info "راه‌اندازی پروتکل‌های اضافه (Hysteria2، TUIC، تونل Cloudflare) و لینک اشتراک..."
    vasl setup-extras
    info "نصب تمام شد! 🎉"
    echo
    vasl sub
    echo
    echo "دستورهای مدیریت:  vasl help"
    exit 0
}

if [[ -f "$STATE" && $REINSTALL -eq 0 ]]; then
    info "نصب قبلی پیدا شد؛ فقط Xray به‌روز شد و کلیدها دست نخوردند."
    systemctl restart xray
    finish
fi

info "ساخت کلیدها..."
KEYS="$("$XRAY" x25519)"
# خروجی نسخه‌های جدید: "PrivateKey: ..." و "Password (PublicKey): ..."
# خروجی نسخه‌های قدیمی: "Private key: ..." و "Public key: ..."
PRIVATE_KEY="$(sed -n '1s/^[^:]*:[[:space:]]*//p' <<<"$KEYS")"
PUBLIC_KEY="$(sed -n '2s/^[^:]*:[[:space:]]*//p' <<<"$KEYS")"
[[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die "خواندن کلیدهای x25519 ناموفق بود:\n$KEYS"
SHORT_ID="$(openssl rand -hex 8)"
XHTTP_PATH="/$(openssl rand -hex 6)"
UUID="$("$XRAY" uuid)"

SERVER_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org || curl -4 -fsS --max-time 10 https://ifconfig.me || true)"
[[ -n "$SERVER_IP" ]] || die "IP عمومی سرور پیدا نشد. با SERVER_IP=x.x.x.x دوباره اجرا کنید."

info "بررسی دامنه‌ی استتار ($SNI)..."
# خروجی را اول در متغیر می‌گیریم؛ grep -q در pipe با pipefail خطای کاذب می‌دهد
SNI_CHECK="$("$XRAY" tls ping "$SNI" 2>&1 || true)"
if ! grep -q "TLS 1.3" <<<"$SNI_CHECK"; then
    warn "به نظر می‌رسد $SNI از TLS 1.3 پشتیبانی نمی‌کند یا در دسترس نیست. بعداً با 'vasl sni-test' دامنه‌ی بهتری پیدا کنید."
fi

info "نوشتن کانفیگ $CONFIG ..."
mkdir -p "$XRAY_DIR"
jq -n \
  --arg uuid "$UUID" --arg user "$FIRST_USER" \
  --arg sni "$SNI" --arg pk "$PRIVATE_KEY" --arg sid "$SHORT_ID" \
  --arg path "$XHTTP_PATH" \
  --argjson vport "$VISION_PORT" --argjson xport "$XHTTP_PORT" '
  def reality: {
    show: false,
    dest: ($sni + ":443"),
    xver: 0,
    serverNames: [$sni],
    privateKey: $pk,
    shortIds: ["", $sid]
  };
  def sniff: { enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true };
  {
    log: { loglevel: "warning" },
    inbounds: [
      {
        tag: "vision", listen: "0.0.0.0", port: $vport, protocol: "vless",
        settings: { clients: [{ id: $uuid, flow: "xtls-rprx-vision", email: $user }], decryption: "none" },
        streamSettings: { network: "raw", security: "reality", realitySettings: reality },
        sniffing: sniff
      },
      {
        tag: "xhttp", listen: "0.0.0.0", port: $xport, protocol: "vless",
        settings: { clients: [{ id: $uuid, email: $user }], decryption: "none" },
        streamSettings: {
          network: "xhttp",
          xhttpSettings: { path: $path, mode: "auto" },
          security: "reality", realitySettings: reality
        },
        sniffing: sniff
      }
    ],
    outbounds: [
      { tag: "direct", protocol: "freedom" },
      { tag: "block", protocol: "blackhole" }
    ],
    routing: {
      domainStrategy: "IPIfNonMatch",
      rules: [
        { type: "field", ip: ["geoip:private"], outboundTag: "block" },
        { type: "field", protocol: ["bittorrent"], outboundTag: "block" }
      ]
    }
  }' > "$CONFIG"
chmod 644 "$CONFIG"

cat > "$STATE" <<EOF
SERVER_IP=$SERVER_IP
SNI=$SNI
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
VISION_PORT=$VISION_PORT
XHTTP_PORT=$XHTTP_PORT
XHTTP_PATH=$XHTTP_PATH
EOF
chmod 600 "$STATE"

"$XRAY" run -test -config "$CONFIG" >/dev/null || die "کانفیگ ساخته‌شده معتبر نیست."

info "فعال‌سازی BBR برای سرعت بهتر..."
cat > /etc/sysctl.d/99-vasl.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
EOF
sysctl --system >/dev/null 2>&1 || warn "اعمال تنظیمات sysctl کامل نشد (روی برخی VPSها عادی است)."

if [[ "$SKIP_FIREWALL" != "1" ]]; then
    info "تنظیم فایروال (ufw)..."
    apt-get install -y -qq ufw >/dev/null
    SSH_PORT="$(ss -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]; exit}')"
    SSH_PORT="${SSH_PORT:-22}"
    ufw allow "$SSH_PORT/tcp" >/dev/null
    ufw allow "$VISION_PORT/tcp" >/dev/null
    ufw allow "$XHTTP_PORT/tcp" >/dev/null
    ufw --force enable >/dev/null
    info "پورت‌های باز: SSH=$SSH_PORT، $VISION_PORT، $XHTTP_PORT"
fi

systemctl enable xray >/dev/null 2>&1
systemctl restart xray
sleep 1
systemctl is-active --quiet xray || die "سرویس Xray بالا نیامد. لاگ: journalctl -u xray -n 50"

finish
