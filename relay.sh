# اسکریپت سرور ایران (ریلی): گوشی ← سرور ایران ← سرور خارج ← اینترنت آزاد
#
# این فایل مستقیم اجرا نمی‌شود. سرور خارج با `vasl relay` یک دستور تک‌خطی می‌دهد که
# متغیرهای DE_* و BASE را بالای همین فایل اضافه می‌کند و روی سرور ایران اجرا می‌شود.
# برای نصب به GitHub نیازی نیست؛ Xray هم از خود سرور خارج دانلود می‌شود.

set -euo pipefail

RELAY_DIR=/usr/local/etc/vasl-relay
CONFIG="$RELAY_DIR/config.json"
XRAY=/usr/local/bin/xray
ASSETS=/usr/local/share/xray
RELAY_PORT="${RELAY_PORT:-443}"

info() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "با root اجرا کنید."

info "نصب پیش‌نیازها (از مخازن داخلی)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || warn "apt update کامل نشد؛ ادامه می‌دهیم."
apt-get install -y -qq curl jq openssl unzip qrencode >/dev/null || true
for c in curl jq openssl unzip; do command -v "$c" >/dev/null || die "برنامه‌ی $c نصب نشد."; done

info "دانلود Xray از سرور خارج ($DE_IP)..."
tmp="$(mktemp -d)"
curl -fsS --retry 3 -o "$tmp/xray.zip" "$BASE/xray.zip" || die "دانلود از سرور خارج ناموفق بود. آیا این سرور به $DE_IP دسترسی دارد؟"
unzip -oq "$tmp/xray.zip" -d "$tmp"
install -m 0755 "$tmp/xray" "$XRAY"
mkdir -p "$ASSETS"; cp "$tmp"/geo*.dat "$ASSETS/"
rm -rf "$tmp"
export XRAY_LOCATION_ASSET="$ASSETS"
"$XRAY" version | sed -n 1p

# --- اتصال سرور ایران به سرور خارج را تست می‌کند و بهترین مسیر را برمی‌دارد ---
de_outbound() {
    if [[ $1 == vision ]]; then
        jq -n --arg ip "$DE_IP" --argjson port "$DE_VPORT" --arg id "$DE_UUID" --arg sni "$DE_SNI" \
              --arg pbk "$DE_PBK" --arg sid "$DE_SID" '{
            tag: "de", protocol: "vless",
            settings: {vnext: [{address: $ip, port: $port, users: [{id: $id, encryption: "none", flow: "xtls-rprx-vision"}]}]},
            streamSettings: {network: "raw", security: "reality",
              realitySettings: {serverName: $sni, fingerprint: "chrome", publicKey: $pbk, shortId: $sid}}}'
    else
        jq -n --arg ip "$DE_IP" --argjson port "$DE_XPORT" --arg id "$DE_UUID" --arg sni "$DE_SNI" \
              --arg pbk "$DE_PBK" --arg sid "$DE_SID" --arg path "$DE_XPATH" '{
            tag: "de", protocol: "vless",
            settings: {vnext: [{address: $ip, port: $port, users: [{id: $id, encryption: "none"}]}]},
            streamSettings: {network: "xhttp", xhttpSettings: {path: $path, mode: "auto"}, security: "reality",
              realitySettings: {serverName: $sni, fingerprint: "chrome", publicKey: $pbk, shortId: $sid}}}'
    fi
}

probe() {  # $1 = JSON یک outbound؛ اگر از طریقش به گوگل برسیم موفق است
    local cfg pid code
    cfg="$(mktemp --suffix=.json)"
    jq -n --argjson ob "$1" '{log: {loglevel: "none"},
        inbounds: [{listen: "127.0.0.1", port: 10898, protocol: "socks", settings: {auth: "noauth"}}],
        outbounds: [$ob]}' > "$cfg"
    "$XRAY" run -config "$cfg" >/dev/null 2>&1 & pid=$!
    sleep 2
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 -x socks5h://127.0.0.1:10898 https://www.google.com/generate_204 || true)"
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -f "$cfg"
    [[ "$code" == 204 ]]
}

info "تست مسیر سرور ایران ← سرور خارج..."
OUTBOUND=""
for mode in vision xhttp; do
    if probe "$(de_outbound $mode)"; then
        info "مسیر $mode کار می‌کند ✅"; OUTBOUND="$(de_outbound $mode)"; break
    fi
    warn "مسیر $mode کار نکرد."
done
[[ -n "$OUTBOUND" ]] || die "این سرور ایران نمی‌تواند به سرور خارج وصل شود. خروجی را برای عیب‌یابی بفرستید."

info "انتخاب یک سایت ایرانی برای استتار..."
IR_SNI=""
for d in ${IR_SNI_CANDIDATES:-www.digikala.com www.aparat.com divar.ir snapp.ir www.shaparak.ir www.irancell.ir www.bmi.ir www.ble.ir rubika.ir www.sep.ir}; do
    out="$("$XRAY" tls ping "$d" 2>&1 || true)"   # بدون pipe؛ grep -q با pipefail خطای کاذب می‌دهد
    if grep -q "TLS 1.3" <<<"$out"; then IR_SNI="$d"; break; fi
done
[[ -n "$IR_SNI" ]] || die "هیچ سایت ایرانی مناسبی (با TLS 1.3) پیدا نشد."
info "سایت استتار: $IR_SNI"

KEYS="$("$XRAY" x25519)"
PRIVATE_KEY="$(sed -n '1s/^[^:]*:[[:space:]]*//p' <<<"$KEYS")"
PUBLIC_KEY="$(sed -n '2s/^[^:]*:[[:space:]]*//p' <<<"$KEYS")"
UUID="$("$XRAY" uuid)"
SHORT_ID="$(openssl rand -hex 8)"

IR_IP="${IR_IP:-$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')}"
[[ -n "$IR_IP" ]] || die "IP این سرور پیدا نشد؛ با IR_IP=x.x.x.x دوباره اجرا کنید."
case "$IR_IP" in 10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*)
    warn "IP پیدا شده ($IR_IP) خصوصی است؛ اگر لینک کار نکرد، با IR_IP=<آی‌پی عمومی> دوباره اجرا کنید." ;;
esac

info "نوشتن کانفیگ..."
mkdir -p "$RELAY_DIR"
jq -n --argjson ob "$OUTBOUND" --argjson port "$RELAY_PORT" --arg id "$UUID" --arg sni "$IR_SNI" \
      --arg pk "$PRIVATE_KEY" --arg sid "$SHORT_ID" '{
    log: {loglevel: "warning"},
    inbounds: [{
        tag: "in", listen: "0.0.0.0", port: $port, protocol: "vless",
        settings: {clients: [{id: $id, flow: "xtls-rprx-vision", email: "relay"}], decryption: "none"},
        streamSettings: {network: "raw", security: "reality", realitySettings: {
            show: false, dest: ($sni + ":443"), xver: 0, serverNames: [$sni],
            privateKey: $pk, shortIds: ["", $sid]}},
        sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}
    }],
    outbounds: [$ob, {tag: "direct", protocol: "freedom"}, {tag: "block", protocol: "blackhole"}],
    routing: {domainStrategy: "IPIfNonMatch", rules: [
        {type: "field", ip: ["geoip:private"], outboundTag: "block"},
        {type: "field", domain: ["geosite:category-ir", "regexp:\\.ir$"], outboundTag: "direct"},
        {type: "field", ip: ["geoip:ir"], outboundTag: "direct"}
    ]}
}' > "$CONFIG"
"$XRAY" run -test -config "$CONFIG" >/dev/null || die "کانفیگ ساخته‌شده معتبر نیست."

cat > /etc/systemd/system/vasl-relay.service <<EOF
[Unit]
Description=vasl Iran relay
After=network.target
[Service]
Environment=XRAY_LOCATION_ASSET=$ASSETS
ExecStart=$XRAY run -config $CONFIG
Restart=always
RestartSec=3
LimitNOFILE=1000000
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q vasl-relay
systemctl restart vasl-relay
sleep 1
systemctl is-active --quiet vasl-relay || die "سرویس بالا نیامد: journalctl -u vasl-relay -n 30"

if command -v ufw >/dev/null && ufw status | grep "Status: active" >/dev/null; then ufw allow "$RELAY_PORT/tcp" >/dev/null; fi

info "تست نهایی: کلاینت ← همین سرور ← سرور خارج..."
FINAL="$(jq -n --argjson port "$RELAY_PORT" --arg id "$UUID" --arg sni "$IR_SNI" --arg pbk "$PUBLIC_KEY" --arg sid "$SHORT_ID" '{
    protocol: "vless",
    settings: {vnext: [{address: "127.0.0.1", port: $port, users: [{id: $id, encryption: "none", flow: "xtls-rprx-vision"}]}]},
    streamSettings: {network: "raw", security: "reality",
      realitySettings: {serverName: $sni, fingerprint: "chrome", publicKey: $pbk, shortId: $sid}}}')"
if probe "$FINAL"; then info "زنجیره کامل کار می‌کند ✅"; else warn "تست نهایی ناموفق بود؛ لاگ: journalctl -u vasl-relay -n 30"; fi

LINK="vless://$UUID@$IR_IP:$RELAY_PORT?encryption=none&security=reality&sni=$IR_SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&flow=xtls-rprx-vision&type=tcp&headerType=none#vasl-iran-relay"

if curl -fsS --max-time 10 -X POST --data-binary "$LINK" "$BASE/register" >/dev/null; then
    info "لینک به لینک اشتراک اضافه شد؛ در برنامه «به‌روزرسانی اشتراک» را بزنید."
else
    warn "ثبت در لینک اشتراک ناموفق بود؛ لینک زیر را دستی وارد کنید."
fi

echo
echo "لینک ریلی ایران:"
echo "$LINK"
echo
qrencode -t ANSIUTF8 "$LINK" 2>/dev/null || true
