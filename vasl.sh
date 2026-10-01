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
