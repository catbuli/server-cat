#!/bin/bash

MENU_NAME="管理 UFW 防火墙"
MENU_FUNC="configure_firewall"
ROLLBACK_FUNC="rollback_firewall"
PRIORITY=10

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"

server_cat_firewall_port_valid() {
    local port="$1"

    is_number "$port" && [[ ${#port} -le 5 ]] &&
        [[ "$((10#$port))" -ge 1 ]] && [[ "$((10#$port))" -le 65535 ]]
}

server_cat_firewall_source_valid() {
    local source="$1"

    [[ "$source" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]]
}

server_cat_firewall_require_ufw() {
    if command -v ufw > /dev/null 2>&1; then
        return 0
    fi

    print_warning "UFW 尚未安装"
    if ! confirm "是否从系统软件源安装 UFW" "n"; then
        return 1
    fi
    if ! apt-get update -qq || ! apt-get install -y ufw; then
        print_error "UFW 安装失败"
        return 1
    fi
}

server_cat_firewall_detect_ssh_ports() {
    local sshd_binary
    local port
    local -a ports

    sshd_binary=$(command -v sshd 2>/dev/null || true)
    [[ -z "$sshd_binary" && -x /usr/sbin/sshd ]] && sshd_binary=/usr/sbin/sshd
    if [[ -n "$sshd_binary" ]]; then
        while IFS= read -r port; do
            if server_cat_firewall_port_valid "$port" &&
                ! server_cat_firewall_array_contains "$port" "${ports[@]}"; then
                ports+=("$port")
            fi
        done < <("$sshd_binary" -T 2>/dev/null | awk '$1 == "port" { print $2 }')
    fi

    if [[ ${#ports[@]} -eq 0 ]] && [[ -n "${SSH_CONNECTION:-}" ]]; then
        port=$(printf '%s\n' "$SSH_CONNECTION" | awk '{ print $4 }')
        server_cat_firewall_port_valid "$port" && ports+=("$port")
    fi

    printf '%s\n' "${ports[@]}"
}

server_cat_firewall_array_contains() {
    local needle="$1"
    local candidate
    shift

    for candidate in "$@"; do
        [[ "$candidate" == "$needle" ]] && return 0
    done
    return 1
}

server_cat_firewall_allow_ssh_before_enable() {
    local port
    local input
    local -a ports

    while IFS= read -r port; do
        if [[ -n "$port" ]] && ! server_cat_firewall_array_contains "$port" "${ports[@]}"; then
            ports+=("$port")
        fi
    done < <(server_cat_firewall_detect_ssh_ports)

    if [[ ${#ports[@]} -eq 0 ]]; then
        print_warning "无法自动识别 SSH 端口，启用防火墙前必须明确填写"
        read -r -p "当前 SSH 服务端口: " input
        if ! server_cat_firewall_port_valid "$input"; then
            print_error "SSH 端口无效，已取消启用防火墙"
            return 1
        fi
        ports+=("$((10#$input))")
    fi

    for port in "${ports[@]}"; do
        print_info "先放行 SSH 端口: $port/tcp"
        if ! ufw allow "$port/tcp"; then
            print_error "无法放行 SSH 端口 $port，已取消启用防火墙"
            return 1
        fi
    done
}

server_cat_firewall_enable() {
    server_cat_firewall_require_ufw || return 1
    print_warning "将设置默认拒绝入站、允许出站，并保留当前 SSH 端口"
    confirm "确认启用 UFW 防火墙" "n" || {
        print_info "已取消启用防火墙"
        return 0
    }

    server_cat_firewall_allow_ssh_before_enable || return 1
    ufw default deny incoming || return 1
    ufw default allow outgoing || return 1
    if ufw --force enable; then
        print_success "UFW 防火墙已启用"
        ufw status verbose
    else
        print_error "UFW 防火墙启用失败"
        return 1
    fi
}

server_cat_firewall_add_rule() {
    local port
    local protocol_choice
    local protocol
    local source

    server_cat_firewall_require_ufw || return 1
    read -r -p "允许访问的端口: " port
    if ! server_cat_firewall_port_valid "$port"; then
        print_error "端口必须是 1 到 65535 之间的整数"
        return 1
    fi
    port=$((10#$port))

    protocol_choice=$(select_menu "选择协议" "$BLUE" "取消" "" "TCP" "UDP")
    case "$protocol_choice" in
        1) protocol=tcp ;;
        2) protocol=udp ;;
        0) return 0 ;;
        *) print_error "无效协议选择"; return 1 ;;
    esac

    read -r -p "允许的来源 IP/CIDR（留空表示任意来源）: " source
    if [[ -n "$source" ]] && ! server_cat_firewall_source_valid "$source"; then
        print_error "来源地址格式无效"
        return 1
    fi

    if [[ -n "$source" ]]; then
        print_warning "将允许 $source 访问 $port/$protocol"
        confirm "确认添加规则" "n" || return 0
        ufw allow from "$source" to any port "$port" proto "$protocol"
    else
        print_warning "将允许任意来源访问 $port/$protocol"
        confirm "确认添加规则" "n" || return 0
        ufw allow "$port/$protocol"
    fi
}

server_cat_firewall_delete_rule() {
    local status_output
    local line
    local number
    local description
    local choice
    local -a rule_numbers
    local -a rule_descriptions

    server_cat_firewall_require_ufw || return 1
    status_output=$(ufw status numbered 2>/dev/null) || {
        print_error "无法读取 UFW 规则"
        return 1
    }

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*\[[[:space:]]*([0-9]+)\][[:space:]]*(.*)$ ]]; then
            number="${BASH_REMATCH[1]}"
            description="${BASH_REMATCH[2]}"
            rule_numbers+=("$number")
            rule_descriptions+=("$description")
        fi
    done <<< "$status_output"

    if [[ ${#rule_numbers[@]} -eq 0 ]]; then
        print_warning "当前没有可删除的 UFW 规则"
        return 0
    fi

    choice=$(select_menu \
        "删除 UFW 规则" \
        "$RED" \
        "取消" \
        "每次只删除一条规则。" \
        "${rule_descriptions[@]}")
    [[ "$choice" -eq 0 ]] && return 0
    if [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#rule_numbers[@]} ]]; then
        print_error "无效规则选择"
        return 1
    fi

    number="${rule_numbers[$((choice - 1))]}"
    description="${rule_descriptions[$((choice - 1))]}"
    print_warning "即将删除规则 [$number] $description"
    confirm "确认删除该规则" "n" || return 0
    ufw --force delete "$number"
}

server_cat_firewall_disable() {
    server_cat_firewall_require_ufw || return 1
    print_warning "停用 UFW 会让现有入站防护规则全部失效"
    confirm_strong "DISABLE" "确认停用 UFW" || {
        print_info "已取消停用防火墙"
        return 0
    }
    ufw --force disable
}

function configure_firewall() {
    local choice

    server_cat_firewall_require_ufw || return 1
    while true; do
        choice=$(select_menu \
            "管理 UFW 防火墙" \
            "$BLUE" \
            "返回常用设置" \
            "启用前会自动识别并放行当前 SSH 端口。" \
            "查看防火墙状态" \
            "添加允许规则" \
            "删除单条规则" \
            "安全启用防火墙" \
            "停用防火墙")

        case "$choice" in
            1) ufw status verbose ;;
            2) server_cat_firewall_add_rule ;;
            3) server_cat_firewall_delete_rule ;;
            4) server_cat_firewall_enable ;;
            5) server_cat_firewall_disable ;;
            0) break ;;
            *) print_error "无效输入，请重试" ;;
        esac

        print_step "请按 [Enter] 键继续..."
        read -r
    done
}

function rollback_firewall() {
    server_cat_firewall_disable
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    configure_firewall
fi
