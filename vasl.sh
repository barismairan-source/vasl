#!/usr/bin/env bash
# ابزار مدیریت VPN شخصی (بعد از نصب با دستور `vasl` در دسترس است)

set -euo pipefail

XRAY=/usr/local/bin/xray
XRAY_DIR=/usr/local/etc/xray
CONFIG="$XRAY_DIR/config.json"
STATE="$XRAY_DIR/vasl.env"

die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
استفاده: vasl <دستور>

  list                 فهرست کاربرها
  add <نام>            ساخت کاربر جدید (برای هر دستگاه/نفر یک کاربر)
  del <نام>            حذف کاربر
  links [نام]          نمایش لینک‌های اتصال (همه یا یک کاربر)
  qr <نام>             نمایش QR Code برای اسکن با گوشی
  sni-test <دامنه>...  بررسی مناسب بودن دامنه برای استتار REALITY
  autofix              امتحان خودکار دامنه‌های استتار تا وقتی سرور سالم شود
  sni <دامنه>          عوض کردن دامنه‌ی استتار
  relay                دستور نصب سرور ایران (ریلی) را می‌دهد
  relay-del            حذف لینک‌های ریلی از اشتراک
  sub                  نمایش لینک اشتراک هر کاربر (همه‌ی روش‌های اتصال در یک لینک)
  setup-extras         نصب/تعمیر Hysteria2، TUIC، تونل Cloudflare و سرور اشتراک
  diag                 عیب‌یابی کامل: تست سرور و بررسی رسیدن بسته‌ها از ایران
  status               وضعیت سرویس و لاگ‌های اخیر
  restart              راه‌اندازی دوباره‌ی سرویس
  update               به‌روزرسانی Xray-core به آخرین نسخه
EOF
}

need_root() { [[ $EUID -eq 0 ]] || die "این دستور باید با sudo اجرا شود."; }

load_state() {
    [[ -f "$STATE" ]] || die "نصب پیدا نشد. اول install.sh را اجرا کنید."
    # shellcheck disable=SC1090
    source "$STATE"
}

users() { jq -r '.inbounds[] | select(.tag=="vision") | .settings.clients[].email' "$CONFIG"; }

uuid_of() {
    jq -r --arg u "$1" '.inbounds[] | select(.tag=="vision") | .settings.clients[] | select(.email==$u) | .id' "$CONFIG"
}

urlencode() { jq -rn --arg s "$1" '$s|@uri'; }

user_links() {
    local name="$1" id
    id="$(uuid_of "$name")"
    [[ -n "$id" ]] || die "کاربر «$name» وجود ندارد."
    [[ ! -s "$RELAY_LINKS" ]] || cat "$RELAY_LINKS"
    local common="encryption=none&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID"
    echo "vless://$id@$SERVER_IP:$VISION_PORT?$common&flow=xtls-rprx-vision&type=tcp&headerType=none#vasl-$name-vision"
    if extras_installed; then
        echo "hysteria2://$id@$SERVER_IP:$HY2_PORT?sni=$HY2_SNI&insecure=1&alpn=h3&obfs=salamander&obfs-password=$OBFS_PASS#vasl-$name-hy2"
        echo "tuic://$id:$id@$SERVER_IP:$TUIC_PORT?congestion_control=bbr&alpn=h3&sni=$HY2_SNI&allow_insecure=1&insecure=1#vasl-$name-tuic"
        local host; host="$(cdn_host)"
        [[ -z "$host" ]] || echo "vless://$id@$host:443?encryption=none&security=tls&sni=$host&host=$host&fp=chrome&alpn=http%2F1.1&type=ws&path=$(urlencode "$WS_PATH")#vasl-$name-cdn"
    fi
    echo "vless://$id@$SERVER_IP:$XHTTP_PORT?$common&type=xhttp&path=$(urlencode "$XHTTP_PATH")&mode=auto#vasl-$name-xhttp"
}

# ---------- پروتکل‌های اضافه: Hysteria2 و TUIC (sing-box)، تونل Cloudflare، لینک اشتراک ----------
SB_BIN=/usr/local/bin/sing-box
SB_CONF="$XRAY_DIR/singbox.json"
CF_BIN=/usr/local/bin/cloudflared
CERT="$XRAY_DIR/vasl-cert.pem"
CERT_KEY="$XRAY_DIR/vasl-key.pem"
SUB_PY=/usr/local/lib/vasl/sub.py

extras_installed() { [[ -f /etc/systemd/system/vasl-singbox.service ]]; }

add_state() { grep -q "^$1=" "$STATE" || echo "$1=$2" >> "$STATE"; }

gh_latest() {
    # آخرین نسخه‌ی یک پروژه در GitHub (بدون API، از روی redirect)
    { curl -fsS -o /dev/null -w '%{redirect_url}' "https://github.com/$1/releases/latest" || true; } | sed 's#.*/tag/##'
}

cdn_host() { curl -s --max-time 3 http://127.0.0.1:20241/quicktunnel 2>/dev/null | jq -r '.hostname // empty' 2>/dev/null || true; }

sub_token() { printf '%s' "$1$SUB_SECRET" | sha256sum | cut -c1-24; }

sub_url() { echo "http://$SERVER_IP:$SUB_PORT/sub/$(sub_token "$(uuid_of "$1")")"; }

RELAY_LINKS="$XRAY_DIR/relay-links.txt"
XRAY_ZIP=/usr/local/share/vasl/xray.zip
relay_token() { printf '%s' "relay$SUB_SECRET" | sha256sum | cut -c1-24; }

render_singbox() {
    extras_installed || return 0
    local users tmp
    users="$(jq -c '[.inbounds[] | select(.tag=="vision") | .settings.clients[] | {name: .email, uuid: .id}]' "$CONFIG")"
    tmp="$(mktemp --suffix=.json)"
    jq -n --argjson users "$users" --arg obfs "$OBFS_PASS" --arg cert "$CERT" --arg key "$CERT_KEY" \
          --argjson hp "$HY2_PORT" --argjson tp "$TUIC_PORT" '
        def tls: {enabled: true, alpn: ["h3"], certificate_path: $cert, key_path: $key};
        {
          log: {level: "warn"},
          inbounds: [
            {type: "hysteria2", tag: "hy2", listen: "::", listen_port: $hp,
             users: [$users[] | {name, password: .uuid}],
             obfs: {type: "salamander", password: $obfs}, tls: tls},
            {type: "tuic", tag: "tuic", listen: "::", listen_port: $tp,
             users: [$users[] | {name, uuid, password: .uuid}],
             congestion_control: "bbr", tls: tls}
          ],
          outbounds: [{type: "direct", tag: "direct"}]
        }' > "$tmp"
    "$SB_BIN" check -c "$tmp" || { rm -f "$tmp"; die "کانفیگ sing-box معتبر نبود."; }
    mv "$tmp" "$SB_CONF"; chmod 600 "$SB_CONF"
    systemctl restart vasl-singbox
}

setup_extras() {
    local arch ver tmp
    case "$(uname -m)" in
        x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;;
        *) die "معماری $(uname -m) پشتیبانی نمی‌شود." ;;
    esac

    add_state HY2_PORT 443
    add_state TUIC_PORT 8443
    add_state HY2_SNI www.bing.com
    add_state OBFS_PASS "$(openssl rand -hex 12)"
    add_state SUB_PORT 2096
    add_state SUB_SECRET "$(openssl rand -hex 16)"
    add_state WS_PORT 10000
    add_state WS_PATH "/$(openssl rand -hex 6)"
    load_state

    echo "  - کپی Xray برای نصب روی سرور ایران (بدون نیاز به GitHub)"
    ver="$("$XRAY" version | awk 'NR==1 {print $2}')"
    if [[ ! -s "$XRAY_ZIP" ]] || ! unzip -p "$XRAY_ZIP" xray 2>/dev/null | cmp -s - "$XRAY"; then
        mkdir -p "$(dirname "$XRAY_ZIP")"
        local xarch=64; [[ $arch == arm64 ]] && xarch=arm64-v8a
        curl -fsSL -o "$XRAY_ZIP" "https://github.com/XTLS/Xray-core/releases/download/v$ver/Xray-linux-$xarch.zip" \
            || echo "  ⚠️ دانلود Xray برای ریلی ناموفق بود."
    fi

    echo "  - sing-box (Hysteria2 + TUIC)"
    ver="$(gh_latest SagerNet/sing-box)"; ver="${ver#v}"; ver="${ver:-1.14.2}"
    if ! "$SB_BIN" version 2>/dev/null | grep -q "version $ver"; then
        tmp="$(mktemp -d)"
        curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v$ver/sing-box-$ver-linux-$arch.tar.gz" | tar xz -C "$tmp"
        install -m 0755 "$tmp"/sing-box-*/sing-box "$SB_BIN"; rm -rf "$tmp"
    fi
    [[ -f "$CERT" ]] || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 -nodes \
        -subj "/CN=$HY2_SNI" -keyout "$CERT_KEY" -out "$CERT" 2>/dev/null
    chmod 600 "$CERT_KEY"
    cat > /etc/systemd/system/vasl-singbox.service <<EOF
[Unit]
Description=vasl sing-box (Hysteria2 + TUIC)
After=network.target
[Service]
ExecStart=$SB_BIN run -c $SB_CONF
Restart=always
RestartSec=3
LimitNOFILE=1000000
[Install]
WantedBy=multi-user.target
EOF

    echo "  - ورودی WebSocket برای تونل Cloudflare"
    if ! jq -e '.inbounds[] | select(.tag=="ws")' "$CONFIG" >/dev/null; then
        tmp="$(mktemp --suffix=.json)"
        jq --argjson port "$WS_PORT" --arg path "$WS_PATH" '
            .inbounds += [{
              tag: "ws", listen: "127.0.0.1", port: $port, protocol: "vless",
              settings: {clients: [.inbounds[] | select(.tag=="xhttp") | .settings.clients[]], decryption: "none"},
              streamSettings: {network: "ws", wsSettings: {path: $path}},
              sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}
            }]' "$CONFIG" > "$tmp"
        apply_config "$tmp"
    fi

    echo "  - cloudflared (تونل رایگان Cloudflare، بدون نیاز به دامنه)"
    if ! "$CF_BIN" --version >/dev/null 2>&1; then
        curl -fsSL -o "$CF_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch"
        chmod 0755 "$CF_BIN"
    fi
    cat > /etc/systemd/system/vasl-cdn.service <<EOF
[Unit]
Description=vasl Cloudflare quick tunnel
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$CF_BIN tunnel --no-autoupdate --metrics 127.0.0.1:20241 --url http://127.0.0.1:$WS_PORT
Restart=always
RestartSec=5
DynamicUser=yes
[Install]
WantedBy=multi-user.target
EOF

    echo "  - سرور لینک اشتراک"
    cat > /etc/systemd/system/vasl-sub.service <<EOF
[Unit]
Description=vasl subscription server
After=network.target
[Service]
ExecStart=/usr/bin/python3 $SUB_PY $SUB_PORT
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "$HY2_PORT/udp" >/dev/null
        ufw allow "$TUIC_PORT/udp" >/dev/null
        ufw allow "$SUB_PORT/tcp" >/dev/null
    fi

    systemctl daemon-reload
    systemctl enable -q vasl-singbox vasl-cdn vasl-sub
    render_singbox
    systemctl restart vasl-cdn vasl-sub
    for _ in $(seq 1 20); do [[ -n "$(cdn_host)" ]] && break; sleep 1; done
    [[ -n "$(cdn_host)" ]] || echo "  ⚠️ تونل Cloudflare هنوز آدرس نگرفته؛ چند دقیقه بعد خودش در لینک اشتراک اضافه می‌شود."
}
# ---------------------------------------------------------------------------------------------

# سرور را از داخل خودش با یک کلاینت واقعی Xray تست می‌کند
SELFTEST_LOG=/tmp/vasl-selftest.log
selftest() {
    local profile="$1" id port flow net cfg pid code
    id="$(uuid_of "$(users | head -1)")"
    if [[ $profile == vision ]]; then
        port=$VISION_PORT; flow=xtls-rprx-vision; net='{"network":"raw"}'
    else
        port=$XHTTP_PORT; flow=""
        net="$(jq -nc --arg p "$XHTTP_PATH" '{network:"xhttp",xhttpSettings:{path:$p,mode:"auto"}}')"
    fi
    cfg="$(mktemp --suffix=.json)"
    jq -n --argjson port "$port" --arg id "$id" --arg flow "$flow" \
          --arg sni "$SNI" --arg pbk "$PUBLIC_KEY" --arg sid "$SHORT_ID" --argjson net "$net" '{
        log: {loglevel: "warning"},
        inbounds: [{listen: "127.0.0.1", port: 10899, protocol: "socks", settings: {auth: "noauth", udp: false}}],
        outbounds: [{protocol: "vless",
          settings: {vnext: [{address: "127.0.0.1", port: $port, users: [{id: $id, encryption: "none", flow: $flow}]}]},
          streamSettings: ($net + {security: "reality",
            realitySettings: {serverName: $sni, fingerprint: "chrome", publicKey: $pbk, shortId: $sid}})}]
    }' > "$cfg"
    "$XRAY" run -config "$cfg" >"$SELFTEST_LOG" 2>&1 & pid=$!
    sleep 2
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -x socks5h://127.0.0.1:10899 https://www.google.com/generate_204 || true)"
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -f "$cfg"
    [[ "$code" == 204 ]]
}

# دامنه‌ی استتار را در کانفیگ و فایل وضعیت عوض می‌کند
set_sni() {
    local sni="$1" tmp
    tmp="$(mktemp --suffix=.json)"
    jq --arg s "$sni" '(.inbounds[].streamSettings.realitySettings) |= (.dest = ($s + ":443") | .serverNames = [$s])' "$CONFIG" > "$tmp"
    apply_config "$tmp"
    sed -i "s/^SNI=.*/SNI=$sni/" "$STATE"
    SNI="$sni"
    sleep 1
}

apply_config() {
    local tmp="$1"
    "$XRAY" run -test -config "$tmp" >/dev/null || { rm -f "$tmp"; die "کانفیگ جدید معتبر نبود؛ تغییری اعمال نشد."; }
    cp "$CONFIG" "$CONFIG.bak"
    mv "$tmp" "$CONFIG"
    chmod 644 "$CONFIG"
    systemctl restart xray
}

cmd="${1:-help}"
shift || true

case "$cmd" in
    list)
        load_state
        users
        ;;
    add)
        need_root; load_state
        name="${1:-}"
        [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "نام فقط می‌تواند حروف انگلیسی، عدد، - و _ باشد."
        [[ -z "$(uuid_of "$name")" ]] || die "کاربر «$name» از قبل وجود دارد."
        id="$("$XRAY" uuid)"
        tmp="$(mktemp --suffix=.json)"
        jq --arg id "$id" --arg u "$name" '
            (.inbounds[] | select(.tag=="vision") | .settings.clients) += [{id: $id, flow: "xtls-rprx-vision", email: $u}]
          | (.inbounds[] | select(.tag=="xhttp" or .tag=="ws") | .settings.clients) += [{id: $id, email: $u}]
        ' "$CONFIG" > "$tmp"
        apply_config "$tmp"
        render_singbox
        echo "کاربر «$name» ساخته شد."
        extras_installed && echo "لینک اشتراک: $(sub_url "$name")"
        user_links "$name"
        ;;
    del)
        need_root; load_state
        name="${1:-}"
        [[ -n "$(uuid_of "$name")" ]] || die "کاربر «$name» وجود ندارد."
        [[ "$(users | wc -l)" -gt 1 ]] || die "آخرین کاربر را نمی‌شود حذف کرد."
        tmp="$(mktemp --suffix=.json)"
        jq --arg u "$name" '(.inbounds[].settings.clients) |= map(select(.email != $u))' "$CONFIG" > "$tmp"
        apply_config "$tmp"
        render_singbox
        echo "کاربر «$name» حذف شد."
        ;;
    links)
        load_state
        if [[ -n "${1:-}" ]]; then
            user_links "$1"
        else
            while read -r u; do
                echo "── $u ──"
                user_links "$u"
                echo
            done < <(users)
        fi
        ;;
    qr)
        load_state
        name="${1:-}"
        [[ -n "$name" ]] || die "نام کاربر را بدهید: vasl qr <نام>"
        while read -r link; do
            echo "${link##*#}"
            qrencode -t ANSIUTF8 "$link"
            echo
        done < <(user_links "$name")
        ;;
    sni-test)
        [[ $# -gt 0 ]] || die "حداقل یک دامنه بدهید: vasl sni-test www.example.com"
        for d in "$@"; do
            out="$("$XRAY" tls ping "$d" 2>&1 || true)"
            if grep -q "TLS 1.3" <<<"$out" && grep -q "Pinging with SNI" <<<"$out"; then
                ms="$(curl -o /dev/null -s -w '%{time_connect}' --max-time 5 "https://$d" || echo "?")"
                printf '✅ %-30s TLS 1.3  (زمان اتصال: %ss)\n' "$d" "$ms"
            else
                printf '❌ %-30s مناسب نیست\n' "$d"
            fi
        done
        echo "دامنه‌ای را انتخاب کنید که ✅ است، زمان اتصالش کم است و در ایران فیلتر نیست."
        ;;
    diag)
        need_root; load_state
        echo "== سرویس =="
        systemctl is-active xray || true
        ss -tlnp | grep xray || echo "Xray روی هیچ پورتی گوش نمی‌دهد!"
        ufw status 2>/dev/null | head -12 || true
        if extras_installed; then
            for svc in vasl-singbox vasl-cdn vasl-sub; do printf '%-14s %s\n' "$svc" "$(systemctl is-active "$svc" || true)"; done
            echo "آدرس تونل Cloudflare: $(cdn_host)"
        fi

        echo; echo "== کلیدها =="
        "$XRAY" version | head -1
        priv="$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$CONFIG")"
        derived="$("$XRAY" x25519 -i "$priv" | sed -n '2s/^[^:]*:[[:space:]]*//p')"
        if [[ "$derived" == "$PUBLIC_KEY" ]]; then echo "✅ کلید عمومی با کلید خصوصی جور است"; else echo "❌ کلید عمومی اشتباه است ($PUBLIC_KEY != $derived)"; fi

        echo; echo "== تست داخلی (SNI: $SNI) =="
        for profile in vision xhttp; do
            if selftest "$profile"; then echo "✅ $profile: سرور سالم است"; else
                echo "❌ $profile: سرور جواب درست نداد. خطای کلاینت:"
                grep -iE "error|fail|warn" "$SELFTEST_LOG" | tail -5 | sed 's/^/    /'
            fi
        done
        echo "لاگ سرور:"
        journalctl -u xray -n 8 --no-pager -o cat | sed 's/^/    /'

        echo; echo "== آیا بسته‌ها از ایران به سرور می‌رسند و جواب می‌گیرند؟ =="
        command -v tcpdump >/dev/null || apt-get install -y -qq tcpdump >/dev/null
        ports="$VISION_PORT $XHTTP_PORT"
        extras_installed && ports="$ports $HY2_PORT $TUIC_PORT"
        filter="$(for p in $ports; do printf 'port %s or ' "$p"; done | sed 's/ or $//')"

        # موقتاً لاگ کامل را روشن می‌کنیم تا ببینیم سرور با اتصال‌ها چه می‌کند
        restore_logs() {
            jq '.log.loglevel = "warning"' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG" && chmod 644 "$CONFIG"
            systemctl restart xray
            render_singbox
        }
        trap restore_logs EXIT
        jq '.log.loglevel = "debug"' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG" && chmod 644 "$CONFIG"
        systemctl restart xray
        if extras_installed; then
            jq '.log.level = "debug"' "$SB_CONF" > "$SB_CONF.tmp" && mv "$SB_CONF.tmp" "$SB_CONF"
            systemctl restart vasl-singbox
        fi
        since="$(date '+%Y-%m-%d %H:%M:%S')"
        sleep 1

        echo "👈 الان ۴۰ ثانیه وقت داری: فیلترشکن رو خاموش کن و توی برنامه به vision وصل شو، چند ثانیه صبر کن، بعد hy2 رو امتحان کن..."
        out="$(timeout 40 tcpdump -nnq -i any "($filter) and not host 127.0.0.1" 2>/dev/null || true)"
        restore_logs; trap - EXIT

        if [[ -z "$out" ]]; then
            echo "❌ هیچ بسته‌ای نرسید؛ مسیر بین ایران و این پورت‌ها بسته است."
        else
            echo "پورت       از-ایران  به-ایران   (تعداد بسته)"
            for p in $ports; do
                for proto in tcp UDP; do
                    in=$(grep -E "\.$p: $proto" <<<"$out" | wc -l)
                    outp=$(grep -E "\.$p > .*: $proto" <<<"$out" | wc -l)
                    [[ $in -eq 0 && $outp -eq 0 ]] || printf '%-10s %-9s %-9s\n' "$p/${proto,,}" "$in" "$outp"
                done
            done
            echo "IPهای وصل‌شده: $(grep -oE '([0-9]+\.){3}[0-9]+\.[0-9]+ >' <<<"$out" | grep -v "$SERVER_IP" | sed -E 's/\.[0-9]+ >//' | sort -u | head -5 | tr '\n' ' ')"
        fi
        echo; echo "== لاگ سرور در این ۴۰ ثانیه =="
        journalctl -u xray -u vasl-singbox --since "$since" --no-pager -o cat 2>/dev/null \
            | grep -iE "reality|accepted|rejected|invalid|fail|error|closed|inbound|authenticat" \
            | grep -v "127.0.0.1" | tail -25 | cut -c1-220 | sed 's/^/    /'
        ;;
    setup-extras)
        need_root; load_state
        setup_extras
        ;;
    sub)
        need_root; load_state
        extras_installed || die "اول 'vasl setup-extras' را اجرا کنید."
        echo "📎 لینک‌های اشتراک (این لینک را در Hiddify / v2rayNG / Streisand وارد کنید؛ اگر در مرورگر باز کنید، صفحه‌ی راهنما و QR می‌بینید):"
        while read -r u; do echo "  $u: $(sub_url "$u")"; done < <(users)
        ;;
    sub-links)
        load_state
        tok="${1:-}"
        while read -r u; do
            if [[ "$(sub_token "$(uuid_of "$u")")" == "$tok" ]]; then user_links "$u"; exit 0; fi
        done < <(users)
        exit 1
        ;;
    relay)
        need_root; load_state
        extras_installed || die "اول 'vasl setup-extras' را اجرا کنید."
        [[ -n "$(uuid_of relay)" ]] || "$0" add relay >/dev/null
        [[ -s "$XRAY_ZIP" ]] || die "فایل Xray برای ریلی آماده نیست؛ 'vasl setup-extras' را دوباره اجرا کنید."
        echo "این دستور را روی سرور ایران (با root) اجرا کنید:"
        echo
        echo "  curl -fsSL http://$SERVER_IP:$SUB_PORT/relay/$(relay_token) | bash"
        echo
        echo "بعد از نصب، لینک ریلی خودکار به اول لینک اشتراک اضافه می‌شود."
        ;;
    relay-check)
        load_state
        [[ "${1:-}" == "$(relay_token)" ]]
        ;;
    relay-script)
        load_state
        [[ "${1:-}" == "$(relay_token)" ]] || exit 1
        id="$(uuid_of relay)"; [[ -n "$id" ]] || exit 1
        printf '#!/usr/bin/env bash\n'
        printf 'DE_IP=%s\nDE_UUID=%s\nDE_PBK=%s\nDE_SID=%s\nDE_SNI=%s\n' "$SERVER_IP" "$id" "$PUBLIC_KEY" "$SHORT_ID" "$SNI"
        printf 'DE_VPORT=%s\nDE_XPORT=%s\nDE_XPATH=%s\n' "$VISION_PORT" "$XHTTP_PORT" "$XHTTP_PATH"
        printf 'BASE=http://%s:%s/relay/%s\n' "$SERVER_IP" "$SUB_PORT" "$1"
        cat /usr/local/lib/vasl/relay.sh
        ;;
    relay-add)
        load_state
        link="${1:-}"
        re='^vless://[0-9a-f-]{36}@[0-9A-Za-z.:-]+:[0-9]+\?[A-Za-z0-9=&%_./-]+#[A-Za-z0-9_.-]+$'
        [[ "$link" =~ $re ]] || die "لینک نامعتبر است."
        touch "$RELAY_LINKS"; chmod 600 "$RELAY_LINKS"
        # هر سرور ایران (IP:پورت) فقط یک لینک دارد؛ لینک قبلی همان سرور جایگزین می‌شود
        hostport="$(sed -E 's#^vless://[^@]+@([^?]+)\?.*#\1#' <<<"$link")"
        grep -vF "@$hostport?" "$RELAY_LINKS" > "$RELAY_LINKS.tmp" || true
        echo "$link" >> "$RELAY_LINKS.tmp"; mv "$RELAY_LINKS.tmp" "$RELAY_LINKS"
        echo "ثبت شد."
        ;;
    relay-del)
        need_root; load_state
        rm -f "$RELAY_LINKS"; echo "همه‌ی لینک‌های ریلی از اشتراک حذف شدند."
        ;;
    sni)
        need_root; load_state
        [[ -n "${1:-}" ]] || die "دامنه را بدهید: vasl sni www.example.com"
        set_sni "$1"
        echo "SNI عوض شد. لینک‌های جدید:"; user_links "$(users | head -1)"
        ;;
    autofix)
        need_root; load_state
        priv="$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$CONFIG")"
        derived="$("$XRAY" x25519 -i "$priv" | sed -n '2s/^[^:]*:[[:space:]]*//p')"
        if [[ -n "$derived" && "$derived" != "$PUBLIC_KEY" ]]; then
            echo "کلید عمومی اشتباه بود؛ درستش کردم."
            sed -i "s/^PUBLIC_KEY=.*/PUBLIC_KEY=$derived/" "$STATE"; PUBLIC_KEY="$derived"
        fi
        for d in "$SNI" www.speedtest.net dl.google.com www.samsung.com www.apple.com addons.mozilla.org www.nvidia.com github.com www.yahoo.com; do
            [[ "$d" == "$SNI" ]] || set_sni "$d"
            printf '%-25s ' "$d"
            if selftest vision && selftest xhttp; then
                echo "✅"; echo; echo "درست شد! لینک‌های جدید (قبلی‌ها را در برنامه پاک کنید):"; echo
                while read -r u; do user_links "$u"; echo; done < <(users); exit 0
            fi
            echo "❌"
        done
        die "هیچ دامنه‌ای کار نکرد. خروجی 'vasl diag' را بفرستید."
        ;;
    status)
        systemctl --no-pager status xray | head -n 5
        echo
        journalctl -u xray -n 20 --no-pager
        ;;
    restart)
        need_root
        systemctl restart xray && echo "انجام شد."
        ;;
    update)
        need_root
        bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
        systemctl restart xray
        "$XRAY" version | head -1
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
