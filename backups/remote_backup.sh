#!/bin/bash
# 远程备份管理

MENU_NAME=""
MENU_FUNC=""
ROLLBACK_FUNC=""

set -eo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "$SCRIPT_DIR/../lib/utils.sh"
source "$SCRIPT_DIR/backup_common.sh"

REMOTE_CONFIG_FILE="/tmp/remote_backup_config"

function configure_remote() {
    print_step "配置远程备份..."

    if [ -f "$REMOTE_CONFIG_FILE" ]; then
        print_info "找到已保存的配置:"
        source "$REMOTE_CONFIG_FILE"
        echo "  主机: $REMOTE_HOST"
        echo "  路径: $REMOTE_PATH"
        echo "  用户: $REMOTE_USER"
        echo ""
        read -p "是否使用已有配置？[y/N]: " use_saved
        if [[ "$use_saved" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi

    echo ""
    print_info "请输入远程服务器信息："

    read -p "远程服务器地址 (IP 或域名): " host
    read -p "远程备份路径 (默认: /backups): " rpath
    read -p "SSH 用户名 (默认: root): " ruser

    REMOTE_HOST="$host"
    REMOTE_PATH="${rpath:-/backups}"
    REMOTE_USER="${ruser:-root}"

    print_info "测试 SSH 连接..."
    if ssh -o ConnectTimeout=5 "${REMOTE_USER}@${REMOTE_HOST}" "echo '连接成功'" 2>/dev/null; then
        print_success "远程服务器连接成功"

        ssh "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p $REMOTE_PATH/{full,daily,weekly,monthly}" 2>/dev/null

        cat > "$REMOTE_CONFIG_FILE" << EOF
REMOTE_HOST="$REMOTE_HOST"
REMOTE_PATH="$REMOTE_PATH"
REMOTE_USER="$REMOTE_USER"
EOF

        print_success "远程备份配置完成"
        return 0
    else
        print_error "无法连接到远程服务器"
        return 1
    fi
}

function copy_to_remote() {
    local local_file="$1"

    if [ ! -f "$local_file" ]; then
        print_error "文件不存在: $local_file"
        return 1
    fi

    if ! configure_remote; then
        return 1
    fi

    source "$REMOTE_CONFIG_FILE"

    print_info "复制备份到远程..."
    print_info "源: $local_file"
    print_info "目标: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/$(basename "$local_file")"

    if scp "$local_file" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/"; then
        print_success "备份已复制到远程"
        return 0
    else
        print_error "复制失败"
        return 1
    fi
}

function sync_to_remote() {
    local backup_type="${1:-full}"

    if ! configure_remote; then
        return 1
    fi

    source "$REMOTE_CONFIG_FILE"

    print_info "同步 $backup_type 备份到远程..."

    if rsync -avz --delete "$BACKUP_ROOT/$backup_type/" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/$backup_type/"; then
        print_success "同步完成"
        return 0
    else
        print_error "同步失败"
        return 1
    fi
}

function test_remote_connection() {
    if [ ! -f "$REMOTE_CONFIG_FILE" ]; then
        print_warning "远程备份未配置"
        return 1
    fi

    source "$REMOTE_CONFIG_FILE"

    print_info "测试远程连接..."
    if ssh -o ConnectTimeout=5 "${REMOTE_USER}@${REMOTE_HOST}" "echo '连接成功'; df -h $REMOTE_PATH | tail -1" 2>/dev/null; then
        print_success "远程连接正常"
        return 0
    else
        print_error "远程连接失败"
        return 1
    fi
}
