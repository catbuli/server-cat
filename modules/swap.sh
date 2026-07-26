#!/bin/bash

MENU_NAME="管理 Swap 文件"
MENU_FUNC="manage_swap_file"
PRIORITY=45

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"

server_cat_swap_file() {
    printf '%s\n' "${SERVER_CAT_SWAP_FILE:-/swapfile}"
}

server_cat_swap_fstab() {
    printf '%s\n' "${SERVER_CAT_FSTAB_FILE:-/etc/fstab}"
}

server_cat_swap_size_valid() {
    local size_gib="$1"

    is_number "$size_gib" && [[ ${#size_gib} -le 2 ]] &&
        [[ "$((10#$size_gib))" -ge 1 ]] && [[ "$((10#$size_gib))" -le 64 ]]
}

server_cat_swap_require_tools() {
    local tool

    for tool in mkswap swapon swapoff truncate; do
        if ! command -v "$tool" > /dev/null 2>&1; then
            print_error "当前系统缺少 $tool，无法管理 Swap"
            return 1
        fi
    done
    if ! command -v fallocate > /dev/null 2>&1 && ! command -v dd > /dev/null 2>&1; then
        print_error "当前系统缺少 fallocate 和 dd，无法创建 Swap 文件"
        return 1
    fi
}

server_cat_swap_is_active() {
    local swap_file="$1"

    swapon --show=NAME --noheadings 2>/dev/null | awk -v target="$swap_file" '$1 == target { found = 1 } END { exit !found }'
}

server_cat_swap_show() {
    local swap_file
    local fstab_file
    local active_swaps
    local file_status="不存在"
    local boot_status="未配置"

    swap_file=$(server_cat_swap_file)
    fstab_file=$(server_cat_swap_fstab)
    if [[ -f "$swap_file" && ! -L "$swap_file" ]]; then
        file_status=$(du -h "$swap_file" 2>/dev/null | awk '{ print $1 }')
        file_status="存在 (${file_status:-大小未知})"
    elif [[ -L "$swap_file" ]]; then
        file_status="拒绝管理：符号链接"
    fi
    if [[ -r "$fstab_file" ]] && awk -v target="$swap_file" '$1 == target && $3 == "swap" { found = 1 } END { exit !found }' "$fstab_file"; then
        boot_status="已配置"
    fi

    print_step "Swap 状态"
    active_swaps=$(swapon --show --noheadings 2>/dev/null || true)
    if [[ -n "$active_swaps" ]]; then
        swapon --show 2>/dev/null || true
    else
        print_info "当前没有活动 Swap"
    fi
    printf '  %-14s %s\n' "$swap_file:" "$file_status"
    printf '  %-14s %s\n' "开机启用:" "$boot_status"
    print_info "仅管理 $swap_file，不修改交换分区或其他 Swap 文件"
}

server_cat_swap_update_fstab() {
    local action="$1"
    local swap_file
    local fstab_file
    local edited_file
    local mode

    swap_file=$(server_cat_swap_file)
    fstab_file=$(server_cat_swap_fstab)
    if [[ ! -f "$fstab_file" ]] || [[ -L "$fstab_file" ]]; then
        print_error "fstab 不存在、不是常规文件或是符号链接: $fstab_file"
        return 1
    fi

    edited_file=$(mktemp "$(dirname "$fstab_file")/.fstab.server-cat.XXXXXX") || return 1
    if ! awk -v target="$swap_file" '$1 != target { print }' "$fstab_file" > "$edited_file"; then
        rm -f "$edited_file"
        return 1
    fi
    if [[ "$action" == "enable" ]]; then
        printf '%s none swap sw 0 0\n' "$swap_file" >> "$edited_file"
    elif [[ "$action" != "disable" ]]; then
        rm -f "$edited_file"
        return 1
    fi

    mode=$(stat -c '%a' "$fstab_file" 2>/dev/null || stat -f '%Lp' "$fstab_file" 2>/dev/null || printf '644')
    chmod "$mode" "$edited_file" || {
        rm -f "$edited_file"
        return 1
    }
    if [[ $EUID -eq 0 ]]; then
        chown --reference="$fstab_file" "$edited_file" || {
            rm -f "$edited_file"
            return 1
        }
    fi
    mv "$edited_file" "$fstab_file"
}

server_cat_swap_available_kib() {
    local swap_file="$1"

    df -Pk "$(dirname "$swap_file")" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

server_cat_swap_existing_kib() {
    local swap_file="$1"
    local bytes=0

    if [[ -f "$swap_file" ]]; then
        bytes=$(stat -c '%s' "$swap_file" 2>/dev/null || stat -f '%z' "$swap_file" 2>/dev/null || printf '0')
    fi
    printf '%s\n' "$((bytes / 1024))"
}

server_cat_swap_has_space() {
    local swap_file="$1"
    local size_gib="$2"
    local available_kib
    local existing_kib
    local required_kib
    local extra_kib
    local reserve_kib=$((256 * 1024))

    available_kib=$(server_cat_swap_available_kib "$swap_file")
    existing_kib=$(server_cat_swap_existing_kib "$swap_file")
    is_number "$available_kib" && is_number "$existing_kib" || return 1
    required_kib=$((size_gib * 1024 * 1024))
    extra_kib=$((required_kib - existing_kib))
    [[ "$extra_kib" -lt 0 ]] && extra_kib=0
    [[ "$available_kib" -ge $((extra_kib + reserve_kib)) ]]
}

server_cat_swap_allocate() {
    local swap_file="$1"
    local size_gib="$2"

    if command -v fallocate > /dev/null 2>&1 && fallocate -l "${size_gib}G" "$swap_file"; then
        truncate -s "${size_gib}G" "$swap_file"
        return $?
    fi

    print_warning "fallocate 不可用，改用 dd 写入 Swap 文件，可能需要较长时间"
    dd if=/dev/zero of="$swap_file" bs=1M count="$((size_gib * 1024))" status=progress
}

server_cat_swap_apply() {
    local size_gib="$1"
    local swap_file
    local was_active=0
    local action_text="创建"

    server_cat_swap_require_tools || return 1
    server_cat_swap_size_valid "$size_gib" || {
        print_error "Swap 大小必须是 1 到 64 GiB 之间的整数"
        return 1
    }
    size_gib=$((10#$size_gib))
    swap_file=$(server_cat_swap_file)

    if [[ -L "$swap_file" ]] || [[ -e "$swap_file" && ! -f "$swap_file" ]]; then
        print_error "拒绝管理符号链接或非常规文件: $swap_file"
        return 1
    fi
    [[ -f "$swap_file" ]] && action_text="调整"
    if ! server_cat_swap_has_space "$swap_file" "$size_gib"; then
        print_error "磁盘可用空间不足；操作后至少需要保留 256 MiB"
        return 1
    fi

    print_warning "将${action_text} $swap_file 为 ${size_gib} GiB"
    print_warning "调整活动 Swap 时会先执行 swapoff，内存不足时系统会拒绝该操作"
    confirm_strong "SWAP" "确认${action_text} Swap 文件" || {
        print_info "已取消 Swap 操作"
        return 0
    }

    if server_cat_swap_is_active "$swap_file"; then
        was_active=1
        if ! swapoff "$swap_file"; then
            print_error "无法停用现有 Swap，文件未修改"
            return 1
        fi
    fi

    if ! server_cat_swap_allocate "$swap_file" "$size_gib" ||
        ! chmod 0600 "$swap_file" ||
        ! mkswap "$swap_file" > /dev/null; then
        server_cat_swap_update_fstab disable > /dev/null 2>&1 || true
        print_error "Swap 文件初始化失败"
        [[ "$was_active" -eq 1 ]] && swapon "$swap_file" > /dev/null 2>&1 || true
        return 1
    fi
    if ! swapon "$swap_file"; then
        server_cat_swap_update_fstab disable > /dev/null 2>&1 || true
        print_error "Swap 文件创建成功，但无法启用；未写入 fstab"
        return 1
    fi
    if ! server_cat_swap_update_fstab enable; then
        swapoff "$swap_file" > /dev/null 2>&1 || true
        print_error "无法安全更新 fstab，已停用新 Swap"
        return 1
    fi

    print_success "$swap_file 已启用，大小 ${size_gib} GiB，并写入 fstab"
}

server_cat_swap_remove() {
    local swap_file

    server_cat_swap_require_tools || return 1
    swap_file=$(server_cat_swap_file)
    if [[ ! -e "$swap_file" ]]; then
        print_info "$swap_file 不存在"
        server_cat_swap_update_fstab disable
        return $?
    fi
    if [[ -L "$swap_file" ]] || [[ ! -f "$swap_file" ]]; then
        print_error "拒绝删除符号链接或非常规文件: $swap_file"
        return 1
    fi

    print_warning "只会删除 $swap_file，不影响其他 Swap"
    confirm_strong "REMOVE" "确认删除受管 Swap 文件" || {
        print_info "已取消删除 Swap"
        return 0
    }

    if server_cat_swap_is_active "$swap_file" && ! swapoff "$swap_file"; then
        print_error "无法停用 $swap_file，已取消删除"
        return 1
    fi
    if ! server_cat_swap_update_fstab disable; then
        swapon "$swap_file" > /dev/null 2>&1 || true
        print_error "无法更新 fstab，已尝试恢复 Swap"
        return 1
    fi
    if ! rm -f "$swap_file"; then
        server_cat_swap_update_fstab enable > /dev/null 2>&1 || true
        swapon "$swap_file" > /dev/null 2>&1 || true
        print_error "无法删除 $swap_file，已尝试恢复配置"
        return 1
    fi

    print_success "$swap_file 已删除"
}

server_cat_swap_choose_size() {
    local choice
    local custom_size

    choice=$(select_menu \
        "选择 Swap 大小" \
        "$BLUE" \
        "取消" \
        "只管理 /swapfile，选择后仍需强确认。" \
        "1 GiB" \
        "2 GiB" \
        "4 GiB" \
        "8 GiB" \
        "自定义大小")

    case "$choice" in
        1|2|3|4)
            case "$choice" in
                1) SERVER_CAT_SWAP_SIZE_GIB=1 ;;
                2) SERVER_CAT_SWAP_SIZE_GIB=2 ;;
                3) SERVER_CAT_SWAP_SIZE_GIB=4 ;;
                4) SERVER_CAT_SWAP_SIZE_GIB=8 ;;
            esac
            ;;
        5)
            read -r -p "Swap 大小（GiB，1-64）: " custom_size
            if ! server_cat_swap_size_valid "$custom_size"; then
                print_error "Swap 大小无效"
                return 1
            fi
            SERVER_CAT_SWAP_SIZE_GIB=$((10#$custom_size))
            ;;
        0) return 1 ;;
        *) print_error "无效大小选择"; return 1 ;;
    esac
}

function manage_swap_file() {
    local choice

    while true; do
        choice=$(select_menu \
            "管理 Swap 文件" \
            "$BLUE" \
            "返回常用设置" \
            "仅管理 /swapfile，不修改交换分区或其他 Swap 文件。" \
            "查看 Swap 状态" \
            "创建或调整 /swapfile" \
            "删除 /swapfile")

        case "$choice" in
            1) server_cat_swap_show ;;
            2)
                if server_cat_swap_choose_size; then
                    server_cat_swap_apply "$SERVER_CAT_SWAP_SIZE_GIB"
                fi
                ;;
            3) server_cat_swap_remove ;;
            0) break ;;
            *) print_error "无效输入，请重试" ;;
        esac

        print_step "请按 [Enter] 键继续..."
        read -r
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    manage_swap_file
fi
