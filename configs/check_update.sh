#!/bin/bash

MENU_NAME="更新 Server Cat"
MENU_FUNC="update_server_cat"
PRIORITY=10

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"
source "$SCRIPT_DIR/../lib/release.sh"

function update_server_cat() {
    server_cat_update_check || return 1

    echo ""
    if ! confirm "已完成更新验证，是否立即安装"; then
        print_info "已取消安装，当前版本保持不变"
        return 0
    fi

    server_cat_update_apply
}
