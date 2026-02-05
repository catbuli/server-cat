#!/bin/bash

MENU_NAME="部署登录状态显示"
MENU_FUNC="deploy_status_script"
ROLLBACK_FUNC="rollback_status_script"
PRIORITY=90

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
DEPLOY_PATH="/etc/update-motd.d/92-server-status.sh"

function deploy_status_script() {
    print_step "▶️  部署登录状态显示..."

    local source_script="$SCRIPT_DIR/../scripts/motd-server-status.sh"

    if [ ! -f "$source_script" ]; then
        print_error "源脚本不存在: $source_script"
        return 1
    fi

    cp "$source_script" "$DEPLOY_PATH"
    chmod +x "$DEPLOY_PATH"

    print_success "✅ 已部署到 $DEPLOY_PATH"
    print_info "下次 SSH 登录时将显示服务器状态"

    return 0
}

function rollback_status_script() {
    print_step "↩️  恢复对登录状态显示的修改..."

    if [ -f "$DEPLOY_PATH" ]; then
        rm -f "$DEPLOY_PATH"
        print_success "✅ 已删除 $DEPLOY_PATH"
    else
        print_info "脚本未部署"
    fi
}
