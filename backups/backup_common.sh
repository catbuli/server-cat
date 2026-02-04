#!/bin/bash
# 备份系统通用函数库

# 默认使用用户目录下的 backups，可通过环境变量覆盖
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/backups}"

function init_backup_dirs() {
    mkdir -p "$BACKUP_ROOT"/{full,daily,weekly,monthly,temp}
    chmod 700 "$BACKUP_ROOT"
}

function get_timestamp() {
    date '+%Y%m%d_%H%M%S'
}

function get_backup_date() {
    date '+%Y-%m-%d'
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

function get_software_versions() {
    local versions="{"
    local first=true

    while IFS=':' read -r name cmd; do
        local version=""
        version=$(eval "$cmd" 2>&1 | head -1 | sed 's/"/\\"/g' | tr '\n' ' ') || version="未安装"

        [ "$first" = true ] && first=false || versions+=","
        versions+="\"$name\":\"$version\""
    done < <(cat "$SCRIPT_DIR/backups/lib/backup_items.sh" | grep '^SOFTWARE_VERSIONS=' | sed "s/^SOFTWARE_VERSIONS=(//" | tr ')' '\n' | grep -v '^$')

    versions+="}"
    echo "$versions"
}

function create_backup_manifest() {
    local temp_dir="$1"
    local backup_type="$2"
    local backup_name="$3"

    local system_info=$(get_system_info)
    local software_versions=$(get_software_versions)

    cat > "$temp_dir/manifest.json" << EOF
{
  "backup_time": "$(date -Iseconds)",
  $system_info,
  "backup_type": "$backup_type",
  "backup_name": "$backup_name",
  "items": [],
  "software_versions": $software_versions
}
EOF
}

function backup_item() {
    local type="$1"
    local source="$2"
    local name="$3"
    local temp_dir="$4"
    local manifest_file="$5"

    local dest="$temp_dir/$name"

    case "$type" in
        dir)
            if [ -d "$source" ]; then
                mkdir -p "$(dirname "$dest")"
                cp -a "$source" "$dest"
                return 0
            fi
            ;;
        file)
            if [ -e "$source" ]; then
                mkdir -p "$(dirname "$dest")"
                cp -a "$source" "$dest"
                return 0
            fi
            ;;
        cmd)
            mkdir -p "$(dirname "$dest")"
            eval "$source" > "$dest.txt" 2>/dev/null
            return 0
            ;;
    esac
    return 1
}

function create_archive() {
    local temp_dir="$1"
    local backup_name="$2"
    local backup_type="$3"

    local archive_file="$BACKUP_ROOT/$backup_type/${backup_name}.tar.gz"

    tar -czf "$archive_file" -C "$(dirname "$temp_dir")" "$(basename "$temp_dir")"
    echo "$archive_file"
}

function cleanup_temp() {
    rm -rf "$BACKUP_ROOT/temp" 2>/dev/null
}

function list_backups_by_type() {
    local type="${1:-}"

    for t in full daily weekly monthly; do
        [ -n "$type" ] && [ "$t" != "$type" ] && continue

        local backups=$(ls -t "$BACKUP_ROOT/$t"/*.tar.gz 2>/dev/null)
        if [ -n "$backups" ]; then
            print_info "[$t 备份]"
            for backup in $backups; do
                local name=$(basename "$backup" .tar.gz)
                local size=$(du -h "$backup" | cut -f1)
                local date=$(stat -c %y "$backup" 2>/dev/null | cut -d'.' -f1)
                echo "  • $name"
                echo "    大小: $size | 日期: $date"
            done
            echo ""
        fi
    done
}
