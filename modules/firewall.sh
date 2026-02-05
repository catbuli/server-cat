#!/bin/bash

MENU_NAME="配置防火墙"
MENU_FUNC="configure_firewall"
ROLLBACK_FUNC="rollback_firewall"
PRIORITY=10

function configure_firewall() {
    print_step "▶️  配置 UFW 防火墙..."

    if ! command -v ufw &> /dev/null; then
        print_info "UFW 未安装，正在尝试安装..."
        apt-get update -qq
        apt-get install -y ufw
    fi

    print_info "设置默认规则：拒绝所有入站，允许所有出站..."
    ufw --force default deny incoming
    ufw --force default allow outgoing

    print_info "允许 SSH (端口 22)..."
    ufw allow ssh

    print_info "允许 HTTP (端口 80)..."
    ufw allow http

    print_info "允许 HTTPS (端口 443)..."
    ufw allow https

    print_info "启用防火墙..."
    echo "y" | ufw enable

    print_success "✅ 防火墙配置完成！"
    print_success "当前防火墙状态:"
    ufw status verbose
}

function rollback_firewall() {
    print_step "↩️  恢复对防火墙的修改..."

    if command -v ufw &> /dev/null; then
        print_warning "⚠️  如需重置防火墙，请手动执行："
        echo ""
        echo "  sudo ufw --force disable"
        echo "  sudo ufw --force reset"
        echo ""
        print_info "📋 查看当前防火墙状态："
        echo "  sudo ufw status verbose"
    else
        print_info "UFW 未安装"
    fi
}
