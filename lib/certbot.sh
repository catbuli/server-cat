#!/bin/bash

# Certbot 安装状态与 Snap 自动续期任务检查。

SERVER_CAT_CERTBOT_RENEW_TIMER="snap.certbot.renew.timer"

server_cat_certbot_is_installed() {
    if command -v certbot > /dev/null 2>&1; then
        return 0
    fi

    command -v snap > /dev/null 2>&1 && snap list certbot > /dev/null 2>&1
}

server_cat_certbot_refresh_renew_timer_status() {
    SERVER_CAT_CERTBOT_TIMER_PRESENT=0
    SERVER_CAT_CERTBOT_TIMER_ENABLED="未知"
    SERVER_CAT_CERTBOT_TIMER_ACTIVE="未知"

    if ! command -v systemctl > /dev/null 2>&1; then
        return 1
    fi

    if ! systemctl cat "$SERVER_CAT_CERTBOT_RENEW_TIMER" > /dev/null 2>&1; then
        return 1
    fi

    SERVER_CAT_CERTBOT_TIMER_PRESENT=1
    SERVER_CAT_CERTBOT_TIMER_ENABLED=$(systemctl is-enabled "$SERVER_CAT_CERTBOT_RENEW_TIMER" 2>/dev/null || true)
    SERVER_CAT_CERTBOT_TIMER_ACTIVE=$(systemctl is-active "$SERVER_CAT_CERTBOT_RENEW_TIMER" 2>/dev/null || true)

    [[ "$SERVER_CAT_CERTBOT_TIMER_ENABLED" == "enabled" && "$SERVER_CAT_CERTBOT_TIMER_ACTIVE" == "active" ]]
}

server_cat_certbot_verify_auto_renewal() {
    if server_cat_certbot_refresh_renew_timer_status; then
        print_success "✅ Certbot 自动续期任务已启用并运行中"
        return 0
    fi

    if [[ "$SERVER_CAT_CERTBOT_TIMER_PRESENT" -eq 0 ]]; then
        print_warning "⚠️  未找到 Certbot 自动续期任务: $SERVER_CAT_CERTBOT_RENEW_TIMER"
    else
        print_warning "⚠️  Certbot 自动续期任务状态异常: $SERVER_CAT_CERTBOT_TIMER_ENABLED ($SERVER_CAT_CERTBOT_TIMER_ACTIVE)"
    fi
    print_warning "请检查 snapd 与 systemd 状态；Server Cat 不会创建额外的 cron 续期任务"

    return 0
}
