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
    local common="encryption=none&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID"
    echo "vless://$id@$SERVER_IP:$VISION_PORT?$common&flow=xtls-rprx-vision&type=tcp&headerType=none#vasl-$name-vision"
    echo "vless://$id@$SERVER_IP:$XHTTP_PORT?$common&type=xhttp&path=$(urlencode "$XHTTP_PATH")&mode=auto#vasl-$name-xhttp"
}

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
          | (.inbounds[] | select(.tag=="xhttp")  | .settings.clients) += [{id: $id, email: $u}]
        ' "$CONFIG" > "$tmp"
        apply_config "$tmp"
        echo "کاربر «$name» ساخته شد:"
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
        ufw status 2>/dev/null | head -8 || true

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

        echo; echo "== آیا بسته‌ها از ایران به سرور می‌رسند؟ =="
        command -v tcpdump >/dev/null || apt-get install -y -qq tcpdump >/dev/null
        echo "👈 الان ۴۰ ثانیه وقت داری: فیلترشکن رو خاموش کن و توی Hiddify دکمه‌ی اتصال رو بزن..."
        out="$(timeout 40 tcpdump -nni any -c 30 "tcp and (dst port $VISION_PORT or dst port $XHTTP_PORT) and not src host $SERVER_IP" 2>/dev/null || true)"
        if [[ -n "$out" ]]; then
            echo "✅ بسته رسید از:"
            awk '{print $3, "->", $5}' <<<"$out" | sed 's/\.[0-9]* ->/ ->/' | sort | uniq -c | head
        else
            echo "❌ هیچ بسته‌ای نرسید؛ مسیر بین ایران و این پورت‌ها بسته است."
        fi
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
