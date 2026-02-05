#!/bin/bash
# 创建备份

MENU_NAME=""
MENU_FUNC="do_create_backup"
ROLLBACK_FUNC=""

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"
source "$SCRIPT_DIR/../lib/backup_tools.sh"

function do_create_backup() {
    local timestamp=$(get_timestamp)
    local temp_dir="$BACKUP_ROOT/temp/backup_${timestamp}"

    print_step "📦 创建备份..."

    cleanup_temp
    init_backup_dirs
    mkdir -p "$temp_dir"

    print_info "备份时间: $(date '+%Y-%m-%d %H:%M:%S')"

    # 收集所有模块的备份项
    print_info "收集备份文件..."
    collect_backup_items "$temp_dir" "$temp_dir/manifest.json"

    # 创建清单文件
    create_backup_manifest "$temp_dir"

    # 创建压缩包
    print_info "创建归档文件..."
    local archive_file=$(create_archive "$temp_dir")

    if [[ -z "$archive_file" ]]; then
        print_error "备份失败：无法创建归档文件"
        cleanup_temp
        return 1
    fi

    local backup_size=$(du -h "$archive_file" | cut -f1)
    cleanup_temp

    print_success "备份完成！"
    echo "  归档文件: $archive_file"
    echo "  备份大小: $backup_size"

    return 0
}

# 如果直接运行此脚本
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    do_create_backup
fi
