#!/bin/bash

MENU_NAME="Certbot 自动续期"
MENU_FUNC="setup_certbot_renew"
ROLLBACK_FUNC="rollback_certbot_renew"
PRIORITY=85

MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$MODULES_DIR/../lib/utils.sh"

function setup_certbot_renew() {
    local user_home="${HOME_DIR:-$(get_real_home)}"
    local scripts_dir="$user_home/scripts"
    local renew_script="$scripts_dir/certbot-renew.sh"
    local source_script
    local cron_job

    # 检测源脚本路径
    if [[ -n "${SERVER_CAT_ROOT:-}" ]]; then
        source_script="$SERVER_CAT_ROOT/scripts/certbot-renew.sh"
    else
        source_script="$MODULES_DIR/../scripts/certbot-renew.sh"
    fi

    print_step "📅 设置证书自动续期任务..."

    # 创建 scripts 目录
    mkdir -p "$scripts_dir"

    # 复制续期脚本
    if [ -f "$source_script" ]; then
        cp "$source_script" "$renew_script"
        chmod +x "$renew_script"
        print_success "✓ 已安装续期脚本到 $renew_script"
    else
        print_error "✗ 找不到源脚本: $source_script"
        return 1
    fi

    # 设置 crontab (每周日凌晨 3 点执行)
    cron_job="0 3 * * 0 $renew_script >/dev/null 2>&1"

    # 检查 crontab 中是否已存在该任务
    if crontab -l 2>/dev/null | grep -q "certbot-renew.sh"; then
        print_info "✓ crontab 任务已存在"
    else
        # 添加到 crontab
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
        print_success "✓ 已添加 crontab 任务 (每周日凌晨 3 点执行)"
    fi

    echo ""
    print_info "📋 当前 crontab 任务："
    crontab -l 2>/dev/null | grep "certbot-renew" || echo "  (无)"

    print_success "✅ 证书自动续期配置完成"
}

function rollback_certbot_renew() {
    print_step "↩️  恢复对证书续期的修改..."

    local renew_script="${HOME_DIR:-$(get_real_home)}/scripts/certbot-renew.sh"

    # 删除续期脚本
    if [ -f "$renew_script" ]; then
        rm -f "$renew_script"
        print_success "✓ 已删除续期脚本"
    fi

    # 删除 crontab 任务
    if crontab -l 2>/dev/null | grep -q "certbot-renew.sh"; then
        crontab -l 2>/dev/null | grep -v "certbot-renew.sh" | crontab -
        print_success "✓ 已删除 crontab 任务"
    fi

    print_success "✅ 证书续期配置已恢复"
}
