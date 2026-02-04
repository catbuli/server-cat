#!/bin/bash
# 创建备份

MENU_NAME=""
MENU_FUNC="do_create_backup"
ROLLBACK_FUNC=""

set -eo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "$SCRIPT_DIR/../lib/utils.sh"
source "$SCRIPT_DIR/backup_common.sh"
source "$SCRIPT_DIR/backup_items.sh"

function do_create_backup() {
    local backup_type="${1:-full}"

    local backup_date=$(get_backup_date)
    local timestamp=$(get_timestamp)
    local backup_name="backup_${backup_type}_${timestamp}"
    local temp_dir="$BACKUP_ROOT/temp/$backup_name"

    print_step "创建 $backup_type 备份..."

    cleanup_temp
    init_backup_dirs
    mkdir -p "$temp_dir"

    print_info "备份名称: $backup_name"

    local manifest_file="$temp_dir/manifest.json"
    create_backup_manifest "$temp_dir" "$backup_type" "$backup_name"

    local success_count=0
    local skip_count=0

    print_info "开始备份文件..."

    for item in "${BACKUP_ITEMS[@]}"; do
        IFS=':' read -r type source name desc <<< "$item"

        print_info "  $desc..."

        if backup_item "$type" "$source" "$name" "$temp_dir" "$manifest_file"; then
            ((success_count++))
        else
            ((skip_count++))
        fi
    done

    print_info "保存项目脚本..."
    mkdir -p "$temp_dir/scripts"
    cp -r "$SCRIPT_DIR/../"*.sh "$temp_dir/scripts/" 2>/dev/null || true
    cp -r "$SCRIPT_DIR/../modules" "$temp_dir/scripts/" 2>/dev/null || true
    cp -r "$SCRIPT_DIR/../softwares" "$temp_dir/scripts/" 2>/dev/null || true
    cp -r "$SCRIPT_DIR/../lib" "$temp_dir/scripts/" 2>/dev/null || true
    cp -r "$SCRIPT_DIR/../backups" "$temp_dir/scripts/" 2>/dev/null || true

    print_info "创建归档文件..."
    local archive_file=$(create_archive "$temp_dir" "$backup_name" "$backup_type")
    local backup_size=$(du -h "$archive_file" | cut -f1)

    cp "$manifest_file" "$BACKUP_ROOT/manifest_${backup_type}_${timestamp}.json"
    cleanup_temp

    print_success "备份完成！"
    echo "  归档文件: $archive_file"
    echo "  备份大小: $backup_size"
    echo "  成功项目: $success_count"
    echo "  跳过项目: $skip_count"

    return 0
}

# 如果直接运行此脚本
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    do_create_backup "${1:-full}"
fi
