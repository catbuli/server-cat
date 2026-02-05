#!/bin/bash
# 恢复备份

MENU_NAME=""
MENU_FUNC="do_restore_backup"
ROLLBACK_FUNC=""

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"
source "$SCRIPT_DIR/../lib/backup_tools.sh"

function find_backup_file() {
    local backup_name="$1"
    local file="$BACKUP_ROOT/${backup_name}.tar.gz"

    if [ -f "$file" ]; then
        echo "$file"
        return 0
    fi
    return 1
}

function restore_ssh_config() {
    local backup_dir="$1"
    local quiet="${2:-}"

    local ssh_backup="$backup_dir/modules/ssh_config/sshd_config"
    if [ -f "$ssh_backup" ]; then
        [ -z "$quiet" ] && print_info "恢复 SSH 配置..."
        cp "$ssh_backup" /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
        [ -z "$quiet" ] && print_success "  ✓ SSH 配置已恢复"
    fi
}

function restore_certbot() {
    local backup_dir="$1"
    local quiet="${2:-}"

    if ! check_command certbot "Certbot"; then
        return 1
    fi

    if [ -d "$backup_dir/softwares/install_certbot/letsencrypt" ]; then
        [ -z "$quiet" ] && print_info "恢复 SSL 证书..."
        cp -af "$backup_dir/softwares/install_certbot/letsencrypt"/. /etc/letsencrypt/
        [ -z "$quiet" ] && print_success "  ✓ SSL 证书已恢复"
    fi
}

function restore_nginx() {
    local backup_dir="$1"
    local quiet="${2:-}"

    if ! check_command nginx "Nginx"; then
        return 1
    fi

    local restored=false

    if [ -d "$backup_dir/softwares/install_nginx/nginx" ]; then
        [ -z "$quiet" ] && print_info "恢复 Nginx 配置..."
        systemctl stop nginx 2>/dev/null || true
        mkdir -p /etc/nginx
        cp -af "$backup_dir/softwares/install_nginx/nginx"/. /etc/nginx/
        [ -z "$quiet" ] && print_success "  ✓ Nginx 配置已恢复"
        restored=true
    fi

    if [ -d "$backup_dir/softwares/install_nginx/html" ]; then
        [ -z "$quiet" ] && print_info "恢复网站文件..."
        mkdir -p /var/www/html
        cp -af "$backup_dir/softwares/install_nginx/html"/. /var/www/html/
        [ -z "$quiet" ] && print_success "  ✓ 网站文件已恢复"
        restored=true
    fi

    if [ "$restored" = true ]; then
        [ -z "$quiet" ] && print_info "  请手动启动: systemctl start nginx"
    fi
}

function restore_docker() {
    local backup_dir="$1"
    local quiet="${2:-}"

    if ! check_command docker "Docker"; then
        return 1
    fi

    if [ -f "$backup_dir/softwares/install_docker/daemon.json" ]; then
        [ -z "$quiet" ] && print_info "恢复 Docker 配置..."
        mkdir -p /etc/docker
        cp "$backup_dir/softwares/install_docker/daemon.json" /etc/docker/daemon.json
        systemctl restart docker 2>/dev/null || true
        [ -z "$quiet" ] && print_success "  ✓ Docker 配置已恢复"
    fi

    if [ -d "$backup_dir/softwares/install_docker/compose" ]; then
        [ -z "$quiet" ] && print_info "恢复 Docker Compose 文件..."
        mkdir -p "$HOME/dockers"
        for compose_dir in "$backup_dir"/softwares/install_docker/compose/*/; do
            if [ -d "$compose_dir" ]; then
                local dir_name=$(basename "$compose_dir")
                cp -af "$compose_dir" "$HOME/dockers/"
                [ -z "$quiet" ] && print_success "  ✓ 已恢复: $dir_name"
            fi
        done
    fi
}

function restore_certbot_renew() {
    local backup_dir="$1"
    local quiet="${2:-}"

    if ! check_command certbot "Certbot"; then
        return 1
    fi

    local restored=false

    if [ -f "$backup_dir/modules/certbot_renew/certbot-renew.sh" ]; then
        [ -z "$quiet" ] && print_info "恢复证书续期脚本..."
        mkdir -p "$HOME/scripts"
        cp "$backup_dir/modules/certbot_renew/certbot-renew.sh" "$HOME/scripts/"
        chmod +x "$HOME/scripts/certbot-renew.sh"
        [ -z "$quiet" ] && print_success "  ✓ 续期脚本已恢复"
        restored=true
    fi

    if [ -f "$backup_dir/modules/certbot_renew/crontab_entry.txt" ]; then
        [ -z "$quiet" ] && print_info "恢复 crontab 任务..."
        local cron_entry=$(cat "$backup_dir/modules/certbot_renew/crontab_entry.txt")
        if ! crontab -l 2>/dev/null | grep -q "certbot-renew.sh"; then
            (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -
            [ -z "$quiet" ] && print_success "  ✓ crontab 任务已恢复"
        fi
        restored=true
    fi

    return 0
}

function restore_all() {
    local backup_dir="$1"
    print_info "恢复全部备份..."

    restore_ssh_config "$backup_dir" "quiet"
    restore_certbot "$backup_dir" "quiet"
    restore_nginx "$backup_dir" "quiet"
    restore_docker "$backup_dir" "quiet"
    restore_certbot_renew "$backup_dir" "quiet"
    restore_user_dirs "$backup_dir" "quiet"

    print_success "全部恢复完成"
}

function restore_user_dirs() {
    local backup_dir="$1"
    local quiet="${2:-}"
    local HOME_DIR="${HOME_DIR:-$HOME}"

    [ -z "$quiet" ] && print_info "恢复用户目录..."

    for dir in logs dockers configs scripts; do
        if [ -d "$backup_dir/$dir" ]; then
            mkdir -p "$HOME_DIR"
            cp -af "$backup_dir/$dir" "$HOME_DIR/"
            [ -z "$quiet" ] && print_success "  ✓ $dir"
        fi
    done
}

function show_backup_contents() {
    local backup_dir="$1"

    print_info "备份内容："
    echo ""

    # 显示 modules
    if [ -d "$backup_dir/modules" ]; then
        echo "  [模块]"
        for module_dir in "$backup_dir/modules"/*/; do
            if [ -d "$module_dir" ]; then
                local module_name=$(basename "$module_dir")
                echo "    • $module_name"
            fi
        done
    fi

    # 显示 softwares
    if [ -d "$backup_dir/softwares" ]; then
        echo "  [软件]"
        for software_dir in "$backup_dir/softwares"/*/; do
            if [ -d "$software_dir" ]; then
                local software_name=$(basename "$software_dir")
                echo "    • $software_name"
            fi
        done
    fi
    echo ""
}

function do_restore_backup() {
    local backup_name="$1"

    if [ -z "$backup_name" ]; then
        print_error "请指定备份名称"
        return 1
    fi

    local backup_file=$(find_backup_file "$backup_name")

    if [ -z "$backup_file" ]; then
        print_error "备份文件不存在: $backup_name"
        return 1
    fi

    print_info "备份文件: $backup_file"

    local temp_dir="$BACKUP_ROOT/temp/restore_${backup_name}"
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir"

    print_info "解压备份..."
    tar -xzf "$backup_file" -C "$temp_dir"

    # 找到实际的解压目录
    local extracted_dir=$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)

    if [ ! -d "$extracted_dir" ]; then
        print_error "备份解压失败"
        rm -rf "$temp_dir"
        return 1
    fi

    # 显示备份内容
    show_backup_contents "$extracted_dir"

    # 交互式选择
    print_prompt "请选择恢复选项："
    echo "  1. 恢复全部"
    echo "  2. 仅恢复 SSH 配置"
    echo "  3. 仅恢复 SSL 证书"
    echo "  4. 仅恢复 Nginx"
    echo "  5. 仅恢复 Docker"
    echo "  6. 仅恢复证书续期"
    echo "  7. 仅恢复用户目录"
    echo "  0. 取消"
    read -p "请输入选项 [0-7]: " choice

    case "$choice" in
        1) restore_all "$extracted_dir" ;;
        2) restore_ssh_config "$extracted_dir" ;;
        3) restore_certbot "$extracted_dir" ;;
        4) restore_nginx "$extracted_dir" ;;
        5) restore_docker "$extracted_dir" ;;
        6) restore_certbot_renew "$extracted_dir" ;;
        7) restore_user_dirs "$extracted_dir" ;;
        0) print_info "已取消恢复" ;;
        *) print_error "无效选项" ;;
    esac

    rm -rf "$temp_dir"

    print_warning "请检查相关服务状态"
}

# 如果直接运行此脚本
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "用法: $0 <备份名称>"
        exit 1
    fi
    do_restore_backup "$@"
fi
