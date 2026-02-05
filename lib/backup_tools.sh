#!/bin/bash
# 备份系统通用函数库

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$SCRIPT_DIR/utils.sh"

BACKUP_ROOT="${BACKUP_ROOT:-$HOME/backups}"

backup_file() {
    local src="$1"
    local temp_dir="$2"
    [ -f "$src" ] || return 0
    mkdir -p "$temp_dir"
    cp "$src" "$temp_dir/"
}

backup_dir() {
    local src="$1"
    local temp_dir="$2"
    [ -d "$src" ] || return 0
    mkdir -p "$temp_dir"
    cp -a "$src" "$temp_dir/"
}

function init_backup_dirs() {
    mkdir -p "$BACKUP_ROOT"
    chmod 700 "$BACKUP_ROOT"
}

function get_timestamp() {
    date '+%Y%m%d_%H%M%S'
}

function get_system_info() {
    cat << EOF
{
  "hostname": "$(hostname)",
  "os": "$(lsb_release -d -s 2>/dev/null || echo 'Unknown')",
  "os_version": "$(lsb_release -r -s 2>/dev/null || echo 'Unknown')",
  "kernel": "$(uname -r)",
  "arch": "$(dpkg --print-architecture)",
  "ip_addresses": "$(ip -4 addr show 2>/dev/null | grep inet | awk '{print $2}' | tr '\n' ' ')"
}
EOF
}

function collect_backup_items() {
    local temp_dir="$1"

    mkdir -p "$temp_dir/modules"
    mkdir -p "$temp_dir/softwares"

    local modules_dir="$SCRIPT_DIR/../modules"
    local softwares_dir="$SCRIPT_DIR/../softwares"

    for script in "$modules_dir"/*.sh; do
        [[ -f "$script" ]] || continue
        source "$script"

        local backup_func=$(get_backup_func "$script")
        if [[ -n "$backup_func" ]]; then
            local module_name=$(basename "$script" .sh)
            print_info "收集备份: $module_name"
            $backup_func "$temp_dir/modules/$module_name"
        fi
    done

    for script in "$softwares_dir"/*.sh; do
        [[ -f "$script" ]] || continue
        source "$script"

        local backup_func=$(get_backup_func "$script")
        if [[ -n "$backup_func" ]]; then
            local software_name=$(basename "$script" .sh)
            print_info "收集备份: $software_name"
            $backup_func "$temp_dir/softwares/$software_name"
        fi
    done
}

function create_backup_manifest() {
    local temp_dir="$1"

    local system_info=$(get_system_info)
    local items=""
    local first=true

    while IFS= read -r -d '' file; do
        local rel_path="${file#$temp_dir/}"
        [ "$rel_path" = "manifest.json" ] && continue

        [ "$first" = true ] && first=false || items+=","
        items+="\"$rel_path\""
    done < <(find "$temp_dir" -type f -print0 2>/dev/null)

    cat > "$temp_dir/manifest.json" << EOF
{
  "backup_time": "$(date -Iseconds)",
  $system_info,
  "items": [$items]
}
EOF
}

function create_archive() {
    local temp_dir="$1"
    local timestamp=$(get_timestamp)
    local archive_name="backup_${timestamp}.tar.gz"
    local archive_file="$BACKUP_ROOT/$archive_name"

    tar -czf "$archive_file" -C "$(dirname "$temp_dir")" "$(basename "$temp_dir")" 2>/dev/null

    if [[ -f "$archive_file" ]]; then
        echo "$archive_file"
    else
        echo ""
    fi
}

function list_backups() {
    local backups=$(ls -t "$BACKUP_ROOT"/backup_*.tar.gz 2>/dev/null)

    if [[ -z "$backups" ]]; then
        print_warning "没有找到备份文件"
        return
    fi

    print_info "📋 备份列表："
    echo ""

    for backup in $backups; do
        local name=$(basename "$backup" .tar.gz)
        local size=$(du -h "$backup" | cut -f1)
        local date=$(stat -c %y "$backup" 2>/dev/null | cut -d'.' -f1)

        echo "  • $name"
        echo "    大小: $size | 日期: $date"
    done
}

function cleanup_temp() {
    rm -rf "$BACKUP_ROOT/temp" 2>/dev/null
}
