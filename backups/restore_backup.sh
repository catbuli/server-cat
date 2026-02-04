#!/bin/bash
# 恢复备份

MENU_NAME=""
MENU_FUNC="do_restore_backup"
ROLLBACK_FUNC=""

set -eo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "$SCRIPT_DIR/../lib/utils.sh"
source "$SCRIPT_DIR/backup_common.sh"

function find_backup_file() {
    local backup_name="$1"

    for type in full daily weekly monthly; do
        local file="$BACKUP_ROOT/$type/${backup_name}.tar.gz"
        if [ -f "$file" ]; then
            echo "$file"
            return 0
        fi
    done
    return 1
}

function restore_user_dirs() {
    local backup_dir="$1"
    local quiet="${2:-}"

    [ -z "$quiet" ] && print_info "恢复用户目录..."

    local dirs=("user_logs" "user_dockers" "user_configs" "user_scripts")
    local targets=("logs" "dockers" "configs" "scripts")

    for i in "${!dirs[@]}"; do
        local dir="${dirs[$i]}"
        local target="${targets[$i]}"
        if [ -d "$backup_dir/$dir" ]; then
            mkdir -p "$HOME/$target"
            cp -af "$backup_dir/$dir/". "$HOME/$target/"
            [ -z "$quiet" ] && print_success "  ✓ $target"
        fi
    done
}

function restore_configs() {
    local backup_dir="$1"
    local quiet="${2:-}"

    [ -z "$quiet" ] && print_info "恢复配置文件..."

    if [ -f "$backup_dir/sshd_config" ]; then
        cp -af "$backup_dir/sshd_config" /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null
        [ -z "$quiet" ] && print_success "  ✓ SSH 配置"
    fi

    if [ -d "$backup_dir/certbot_certs" ]; then
        cp -af "$backup_dir/certbot_certs"/. /etc/letsencrypt/
        [ -z "$quiet" ] && print_success "  ✓ SSL 证书"
    fi
}

function restore_nginx() {
    local backup_dir="$1"
    local quiet="${2:-}"

    [ -z "$quiet" ] && print_info "恢复 Nginx..."

    if [ -d "$backup_dir/nginx_config" ]; then
        systemctl stop nginx 2>/dev/null
        rm -rf /etc/nginx
        cp -af "$backup_dir/nginx_config" /etc/nginx
        [ -z "$quiet" ] && print_success "  ✓ Nginx 配置"
    fi

    if [ -d "$backup_dir/nginx_html" ]; then
        cp -af "$backup_dir/nginx_html"/. /var/www/html/
        [ -z "$quiet" ] && print_success "  ✓ 网站文件"
    fi

    [ -z "$quiet" ] && print_info "  请手动启动: systemctl start nginx"
}

function restore_all() {
    local backup_dir="$1"
    print_info "恢复全部..."
    restore_user_dirs "$backup_dir" "quiet"
    restore_configs "$backup_dir" "quiet"
    restore_nginx "$backup_dir" "quiet"
    print_success "全部恢复完成"
}

function do_restore_backup() {
    local backup_name="$1"
    local restore_mode="${2:-}"  # all, user, configs, nginx

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
    mkdir -p "$temp_dir"

    print_info "解压备份..."
    tar -xzf "$backup_file" -C "$temp_dir"

    local extracted_dir="$temp_dir/$backup_name"

    if [ ! -d "$extracted_dir" ]; then
        # 尝试找到实际的目录名
        extracted_dir=$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
    fi

    if [ ! -d "$extracted_dir" ]; then
        print_error "备份解压失败"
        rm -rf "$temp_dir"
        return 1
    fi

    case "$restore_mode" in
        all)
            restore_all "$extracted_dir"
            ;;
        user)
            restore_user_dirs "$extracted_dir"
            ;;
        configs)
            restore_configs "$extracted_dir"
            ;;
        nginx)
            restore_nginx "$extracted_dir"
            ;;
        *)
            print_info "恢复模式: $restore_mode (未指定，交互式选择)"
            echo ""
            print_prompt "请选择恢复选项："
            echo "  1. 恢复全部"
            echo "  2. 仅恢复用户目录"
            echo "  3. 仅恢复配置文件"
            echo "  4. 仅恢复 Nginx"
            read -p "请输入选项 [1-4]: " choice

            case "$choice" in
                1) restore_all "$extracted_dir" ;;
                2) restore_user_dirs "$extracted_dir" ;;
                3) restore_configs "$extracted_dir" ;;
                4) restore_nginx "$extracted_dir" ;;
                *) print_error "无效选项" ;;
            esac
            ;;
    esac

    rm -rf "$temp_dir"

    print_success "恢复完成"
    print_warning "请检查相关服务状态"
}

# 如果直接运行此脚本
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "用法: $0 <备份名称> [恢复模式]"
        echo "恢复模式: all | user | configs | nginx"
        exit 1
    fi
    do_restore_backup "$@"
fi
