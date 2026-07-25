#!/bin/bash

MENU_NAME="Certbot (SSL证书)"
MENU_FUNC="install_certbot"
ROLLBACK_FUNC="rollback_certbot"
PRIORITY=30

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"

function install_certbot() {
    echo "======================================"
    echo "  📦 Certbot 安装脚本"
    echo "======================================"

    print_step "[1/6] 更新 apt 包列表..."
    if ! apt-get update -qq; then
        print_error "apt update 失败"
        return 1
    fi

    print_step "[2/6] 确保 snapd 已安装..."
    if ! command -v snap &> /dev/null; then
        print_info "正在安装 snapd..."
        if ! apt-get install -y snapd > /dev/null; then
            print_error "snapd 安装失败"
            return 1
        fi
    else
        print_info "snapd 已安装"
    fi

    print_step "[3/6] 更新 snap 核心..."
    if ! snap list core &>/dev/null; then
        snap install core 2>/dev/null || print_warning "core 安装跳过"
    else
        snap refresh core 2>&1 | grep -v "has no updates available" || true
    fi

    print_step "[4/6] 移除可能存在的旧版本 certbot..."
    apt-get remove -y certbot 2>/dev/null || true

    print_step "[5/6] 安装 Certbot (snap 版本)..."
    if snap list certbot &> /dev/null; then
        print_info "Certbot 已通过 snap 安装"
    else
        if ! snap install --classic certbot 2>&1; then
            print_error "Certbot 安装失败"
            print_warning "请检查网络连接或手动安装: snap install --classic certbot"
            return 1
        fi
    fi

    print_step "[6/6] 创建 certbot 命令的符号链接..."
    ln -sf /snap/bin/certbot /usr/bin/certbot

    if ! command -v certbot &> /dev/null; then
        print_error "Certbot 命令不可用"
        return 1
    fi

    echo ""
    print_success "✅ Certbot 安装成功！"
    certbot --version 2>/dev/null || echo "  • Certbot: 已安装"

    echo ""
    print_info "📝 使用提示："
    echo "  • 为域名申请证书: sudo certbot --nginx -d yourdomain.com"
    echo "  • 为 Apache 申请: sudo certbot --apache -d yourdomain.com"
    echo "  • 仅获取证书: sudo certbot certonly --standalone -d yourdomain.com"
    echo "  • 查看已有证书: sudo certbot certificates"
    echo "  • 续期证书: sudo certbot renew"
    echo "  • Snap 会通过系统任务自动尝试续期，无需额外配置定时任务"
    echo ""

    return 0
}

function rollback_certbot() {
    print_step "↩️  卸载 Certbot..."

    print_warning "⚠️  此操作将卸载 Certbot"
    print_warning "⚠️  已申请的 SSL 证书将无法自动续期"

    if confirm "确认卸载"; then
        if snap list certbot &> /dev/null; then
            snap remove --purge certbot
            print_success "✅ Certbot 已卸载"
        else
            print_warning "Certbot 未通过 snap 安装"
        fi

        rm -f /usr/bin/certbot
    else
        print_warning "已取消卸载"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_certbot
fi
