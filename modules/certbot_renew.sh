#!/bin/bash

MENU_NAME="Certbot 自动续期"
MENU_FUNC="setup_certbot_renew"
ROLLBACK_FUNC="rollback_certbot_renew"
BACKUP_FUNC="backup_certbot_renew"
PRIORITY=85

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"
source "$SCRIPT_DIR/../lib/backup_tools.sh"

function setup_certbot_renew() {
    SCRIPTS_DIR="$HOME/scripts"
    RENEW_SCRIPT="$SCRIPTS_DIR/certbot-renew.sh"

    # 检测源脚本路径
    if [[ -n "${SERVER_CAT_ROOT:-}" ]]; then
        SOURCE_SCRIPT="$SERVER_CAT_ROOT/scripts/certbot-renew.sh"
    else
        SOURCE_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/../scripts/certbot-renew.sh"
    fi

    print_step "📅 设置证书自动续期任务..."

    # 创建 scripts 目录
    mkdir -p "$SCRIPTS_DIR"

    # 复制续期脚本
    if [ -f "$SOURCE_SCRIPT" ]; then
        cp "$SOURCE_SCRIPT" "$RENEW_SCRIPT"
        chmod +x "$RENEW_SCRIPT"
        print_success "✓ 已安装续期脚本到 $RENEW_SCRIPT"
    else
        print_error "✗ 找不到源脚本: $SOURCE_SCRIPT"
        return 1
    fi

    # 设置 crontab (每周日凌晨 3 点执行)
    CRON_JOB="0 3 * * 0 $RENEW_SCRIPT >/dev/null 2>&1"

    # 检查 crontab 中是否已存在该任务
    if crontab -l 2>/dev/null | grep -q "certbot-renew.sh"; then
        print_info "✓ crontab 任务已存在"
    else
        # 添加到 crontab
        (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
        print_success "✓ 已添加 crontab 任务 (每周日凌晨 3 点执行)"
    fi

    echo ""
    print_info "📋 当前 crontab 任务："
    crontab -l 2>/dev/null | grep "certbot-renew" || echo "  (无)"

    print_success "✅ 证书自动续期配置完成"
}

function rollback_certbot_renew() {
    print_step "↩️  恢复对证书续期的修改..."

    local RENEW_SCRIPT="$HOME/scripts/certbot-renew.sh"

    # 删除续期脚本
    if [ -f "$RENEW_SCRIPT" ]; then
        rm -f "$RENEW_SCRIPT"
        print_success "✓ 已删除续期脚本"
    fi

    # 删除 crontab 任务
    if crontab -l 2>/dev/null | grep -q "certbot-renew.sh"; then
        crontab -l 2>/dev/null | grep -v "certbot-renew.sh" | crontab -
        print_success "✓ 已删除 crontab 任务"
    fi

    print_success "✅ 证书续期配置已恢复"
}

function backup_certbot_renew() {
    local temp_dir="$1"

    backup_file "$HOME/scripts/certbot-renew.sh" "$temp_dir"

    if crontab -l 2>/dev/null | grep -q "certbot-renew.sh"; then
        mkdir -p "$temp_dir"
        crontab -l 2>/dev/null | grep "certbot-renew.sh" > "$temp_dir/crontab_entry.txt"
    fi
}
