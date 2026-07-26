#!/bin/bash

MENU_NAME="主机名与时间设置"
MENU_FUNC="configure_system_identity"
PRIORITY=40

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"

server_cat_hostname_valid() {
    local hostname_value="$1"
    local label
    local -a labels

    [[ -n "$hostname_value" ]] && [[ ${#hostname_value} -le 253 ]] || return 1
    [[ "$hostname_value" != .* && "$hostname_value" != *. && "$hostname_value" != *..* ]] || return 1

    IFS='.' read -r -a labels <<< "$hostname_value"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

server_cat_system_identity_require_tools() {
    local tool

    for tool in hostnamectl timedatectl; do
        if ! command -v "$tool" > /dev/null 2>&1; then
            print_error "当前系统缺少 $tool"
            return 1
        fi
    done
}

server_cat_system_identity_show() {
    local hostname_value
    local timezone
    local ntp_enabled
    local ntp_synchronized

    hostname_value=$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || printf '未知')
    timezone=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
    ntp_enabled=$(timedatectl show --property=NTP --value 2>/dev/null || true)
    ntp_synchronized=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || true)

    print_step "主机名与时间状态"
    printf '  %-12s %s\n' "主机名:" "$hostname_value"
    printf '  %-12s %s\n' "时区:" "${timezone:-未知}"
    printf '  %-12s %s\n' "NTP:" "${ntp_enabled:-未知}"
    printf '  %-12s %s\n' "时间已同步:" "${ntp_synchronized:-未知}"
    printf '  %-12s %s\n' "当前时间:" "$(date '+%F %T %Z')"
}

server_cat_system_identity_set_hostname() {
    local current
    local new_hostname

    current=$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || true)
    read -r -p "新主机名 [当前: ${current:-未知}]: " new_hostname
    if ! server_cat_hostname_valid "$new_hostname"; then
        print_error "主机名无效；每段只能包含字母、数字和中划线，且不能以中划线开头或结尾"
        return 1
    fi
    if [[ "$new_hostname" == "$current" ]]; then
        print_info "主机名未发生变化"
        return 0
    fi

    print_warning "将主机名从 ${current:-未知} 修改为 $new_hostname"
    confirm "确认修改主机名" "n" || return 0
    if hostnamectl set-hostname "$new_hostname"; then
        print_success "主机名已修改为 $new_hostname"
    else
        print_error "主机名修改失败"
        return 1
    fi
}

server_cat_system_identity_select_timezone() {
    local keyword
    local timezone
    local choice
    local -a matches

    read -r -p "输入时区关键词（例如 Shanghai、Asia）: " keyword
    if [[ ${#keyword} -lt 2 ]] || [[ ! "$keyword" =~ ^[A-Za-z0-9_+/-]+$ ]]; then
        print_error "请输入至少 2 个有效字符"
        return 1
    fi

    while IFS= read -r timezone; do
        [[ -n "$timezone" ]] && matches+=("$timezone")
    done < <(timedatectl list-timezones 2>/dev/null | awk -v keyword="$keyword" 'index(tolower($0), tolower(keyword))')

    if [[ ${#matches[@]} -eq 0 ]]; then
        print_warning "没有找到匹配的时区"
        return 1
    fi
    if [[ ${#matches[@]} -gt 50 ]]; then
        print_warning "匹配到 ${#matches[@]} 个时区，请输入更具体的关键词"
        return 1
    fi

    choice=$(select_menu "选择时区" "$BLUE" "取消" "" "${matches[@]}")
    [[ "$choice" -eq 0 ]] && return 0
    if [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#matches[@]} ]]; then
        print_error "无效时区选择"
        return 1
    fi

    timezone="${matches[$((choice - 1))]}"
    print_warning "将系统时区修改为 $timezone"
    confirm "确认修改时区" "n" || return 0
    if timedatectl set-timezone "$timezone"; then
        print_success "系统时区已修改为 $timezone"
    else
        print_error "系统时区修改失败"
        return 1
    fi
}

server_cat_system_identity_set_ntp() {
    local enabled="$1"
    local action_text="停用"

    [[ "$enabled" == "true" ]] && action_text="启用"
    print_warning "将${action_text}系统自动时间同步"
    confirm "确认${action_text} NTP" "n" || return 0
    if timedatectl set-ntp "$enabled"; then
        print_success "已${action_text}系统自动时间同步"
    else
        print_error "无法${action_text}系统自动时间同步"
        return 1
    fi
}

function configure_system_identity() {
    local choice

    server_cat_system_identity_require_tools || return 1
    while true; do
        choice=$(select_menu \
            "主机名与时间设置" \
            "$BLUE" \
            "返回常用设置" \
            "所有修改均通过 systemd 提供的系统接口执行。" \
            "查看当前状态" \
            "修改主机名" \
            "修改时区" \
            "启用自动时间同步" \
            "停用自动时间同步")

        case "$choice" in
            1) server_cat_system_identity_show ;;
            2) server_cat_system_identity_set_hostname ;;
            3) server_cat_system_identity_select_timezone ;;
            4) server_cat_system_identity_set_ntp true ;;
            5) server_cat_system_identity_set_ntp false ;;
            0) break ;;
            *) print_error "无效输入，请重试" ;;
        esac

        print_step "请按 [Enter] 键继续..."
        read -r
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    configure_system_identity
fi
