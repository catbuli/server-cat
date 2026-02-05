#!/bin/bash

MENU_NAME="Nginx"
MENU_FUNC="install_nginx"
ROLLBACK_FUNC="rollback_nginx"
BACKUP_FUNC="backup_nginx"
PRIORITY=20

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"
source "$SCRIPT_DIR/../lib/backup_tools.sh"

function install_nginx() {
    echo "======================================"
    echo "  📦 Nginx 安装脚本"
    echo "======================================"

    print_step "[1/4] 更新 apt 包列表..."
    if ! apt-get update -qq; then
        print_error "apt update 失败"
        return 1
    fi

    print_step "[2/4] 安装 Nginx..."
    if ! apt-get install -y nginx > /dev/null; then
        print_error "Nginx 安装失败"
        return 1
    fi

    print_step "[3/4] 启动并设置开机自启 Nginx..."
    systemctl start nginx || true
    systemctl enable nginx || true

    print_step "[4/4] 验证 Nginx 状态..."
    if systemctl is-active --quiet nginx; then
        print_info "  • Nginx 服务正在运行"
    else
        print_error "  • Nginx 服务启动失败"
        return 1
    fi

    if systemctl is-enabled --quiet nginx; then
        print_info "  • Nginx 已设置为开机自启"
    else
        print_warning "  • Nginx 未能设置为开机自启"
    fi

    echo ""
    print_success "✅ Nginx 安装成功！"

    print_info "📝 使用提示："
    echo "  • Nginx 版本: $(nginx -v 2>&1)"
    echo "  • 默认网站目录: /var/www/html"
    echo "  • 主配置文件: /etc/nginx/nginx.conf"
    echo "  • 网站配置文件目录: /etc/nginx/sites-available/"
    echo "  • 在浏览器中访问服务器 IP 地址，应该能看到 Nginx 欢迎页面"

    return 0
}

function rollback_nginx() {
    print_step "↩️  卸载 Nginx..."

    print_warning "⚠️  此操作将卸载 Nginx 并删除配置文件"
    print_warning "⚠️  /etc/nginx 目录将被删除（如有自定义配置请先备份）"

    confirm_strong "YES" "确认卸载" || {
        print_warning "已取消卸载"
        return 0
    }

    systemctl stop nginx 2>/dev/null || true

    apt-get purge -y nginx nginx-common 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true

    print_success "✅ Nginx 已卸载"
}

function backup_nginx() {
    local temp_dir="$1"

    backup_dir "/etc/nginx" "$temp_dir"
    backup_dir "/var/www/html" "$temp_dir"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_nginx
fi
