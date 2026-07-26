#!/bin/bash

MENU_NAME="Ncdu (磁盘分析)"
MENU_FUNC="install_ncdu"
ROLLBACK_FUNC="rollback_ncdu"
PRIORITY=90

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"

function install_ncdu() {
    print_step "[1/3] 更新 apt 包列表..."
    if ! apt-get update -qq; then
        print_error "apt update 失败"
        return 1
    fi

    print_step "[2/3] 安装 Ncdu..."
    if ! apt-get install -y ncdu > /dev/null; then
        print_error "Ncdu 安装失败"
        return 1
    fi

    print_step "[3/3] 验证安装..."
    if ! command -v ncdu > /dev/null 2>&1; then
        print_error "Ncdu 命令不可用"
        return 1
    fi

    print_success "Ncdu 安装成功"
    print_info "运行 ncdu / 分析根文件系统，按 q 退出"
}

function rollback_ncdu() {
    print_warning "此操作将卸载 Ncdu"

    if ! confirm "确认卸载"; then
        print_warning "已取消卸载"
        return 0
    fi

    if ! apt-get remove -y ncdu > /dev/null; then
        print_error "Ncdu 卸载失败"
        return 1
    fi

    print_success "Ncdu 已卸载"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_ncdu
fi
