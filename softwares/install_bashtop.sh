#!/bin/bash

MENU_NAME="Bashtop"
MENU_FUNC="install_bashtop"
ROLLBACK_FUNC="rollback_bashtop"
PRIORITY=100

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "$SCRIPT_DIR/../lib/utils.sh"

function install_bashtop() {
    echo "======================================"
    echo "  📦 Bashtop 安装脚本"
    echo "======================================"

    print_step "[1/3] 更新 apt 包列表..."
    if ! apt-get update -qq; then
        print_error "apt update 失败"
        return 1
    fi

    print_step "[2/3] 安装 Bashtop..."
    if ! apt-get install -y bashtop > /dev/null; then
        print_error "Bashtop 安装失败"
        return 1
    fi

    print_step "[3/3] 验证安装..."
    if command -v bashtop &> /dev/null; then
        print_success "✅ Bashtop 安装成功！"
        echo ""
        print_info "📝 使用提示："
        echo "  • 运行命令: bashtop"
        echo "  • 退出: 按 q"
        echo "  • 帮助: 按 F1"
    else
        print_error "Bashtop 安装失败"
        return 1
    fi

    return 0
}

function rollback_bashtop() {
    print_step "↩️  恢复 Bashtop..."

    print_warning "⚠️  此操作将卸载 Bashtop"
    read -p "确认卸载? (y/n): " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        apt-get remove -y bashtop 2>/dev/null || true
        print_success "✅ Bashtop 已卸载"
    else
        print_warning "已取消卸载"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_bashtop
fi
