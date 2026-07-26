#!/bin/bash

# 服务器只读概览。依赖调用方已加载 lib/utils.sh。

server_cat_overview_row() {
    printf '  %-14s %s\n' "$1:" "$2"
}

server_cat_overview_nonempty_line_count() {
    awk 'NF { count++ } END { print count + 0 }'
}

server_cat_overview_memory() {
    local meminfo_file="${SERVER_CAT_MEMINFO_FILE:-/proc/meminfo}"

    awk '
        /^MemTotal:/ { total = $2 }
        /^MemAvailable:/ { available = $2 }
        /^SwapTotal:/ { swap_total = $2 }
        /^SwapFree:/ { swap_free = $2 }
        END {
            if (total > 0) {
                printf "%.1f%% (%d/%d MiB)\n", (total - available) * 100 / total, (total - available) / 1024, total / 1024
            } else {
                print "无法读取"
            }
            if (swap_total > 0) {
                printf "%.1f%% (%d/%d MiB)\n", (swap_total - swap_free) * 100 / swap_total, (swap_total - swap_free) / 1024, swap_total / 1024
            } else {
                print "未配置"
            }
        }
    ' "$meminfo_file" 2>/dev/null
}

server_cat_overview_disk() {
    local option="$1"
    local output

    if [[ "$option" == "inode" ]]; then
        output=$(df -Pi / 2>/dev/null | awk 'NR == 2 { printf "%s (%s/%s)\n", $5, $3, $2 }')
    else
        output=$(df -Ph / 2>/dev/null | awk 'NR == 2 { printf "%s (%s/%s)\n", $5, $3, $2 }')
    fi
    printf '%s\n' "${output:-无法读取}"
}

server_cat_overview_docker() {
    local running
    local total
    local unhealthy

    if ! command -v docker > /dev/null 2>&1; then
        printf '未安装\n'
        return 0
    fi
    if ! docker info > /dev/null 2>&1; then
        printf '服务不可用\n'
        return 0
    fi

    running=$(docker ps --quiet 2>/dev/null | server_cat_overview_nonempty_line_count)
    total=$(docker ps --all --quiet 2>/dev/null | server_cat_overview_nonempty_line_count)
    unhealthy=$(docker ps --filter health=unhealthy --quiet 2>/dev/null | server_cat_overview_nonempty_line_count)
    printf '运行 %s / 总计 %s，异常健康状态 %s\n' "$running" "$total" "$unhealthy"
}

server_cat_overview_agent_timer() {
    local enabled
    local active

    if ! command -v systemctl > /dev/null 2>&1 ||
        ! systemctl cat server-cat-agent.timer > /dev/null 2>&1; then
        printf '未安装\n'
        return 0
    fi

    enabled=$(systemctl is-enabled server-cat-agent.timer 2>/dev/null || true)
    active=$(systemctl is-active server-cat-agent.timer 2>/dev/null || true)
    printf '%s (%s)\n' "${enabled:-未知}" "${active:-未知}"
}

server_cat_overview() {
    local os_release_file="${SERVER_CAT_OS_RELEASE_FILE:-/etc/os-release}"
    local loadavg_file="${SERVER_CAT_LOADAVG_FILE:-/proc/loadavg}"
    local reboot_required_file="${SERVER_CAT_REBOOT_REQUIRED_FILE:-/var/run/reboot-required}"
    local os_name="未知"
    local host_name
    local uptime_text
    local cpu_count
    local load_average="无法读取"
    local private_ip="未发现"
    local failed_services="未知"
    local listening_ports="未知"
    local memory_lines
    local memory_usage
    local swap_usage

    if [[ -r "$os_release_file" ]]; then
        os_name=$(awk -F= '/^PRETTY_NAME=/{ value = substr($0, index($0, "=") + 1); gsub(/^"|"$/, "", value); print value; exit }' "$os_release_file")
    fi
    host_name=$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf '未知')
    uptime_text=$(uptime -p 2>/dev/null || printf '无法读取')
    cpu_count=$(nproc 2>/dev/null || printf '未知')
    [[ -r "$loadavg_file" ]] && load_average=$(awk '{ print $1, $2, $3 }' "$loadavg_file")
    if command -v hostname > /dev/null 2>&1; then
        private_ip=$(hostname -I 2>/dev/null | awk '{ print $1 }')
        private_ip="${private_ip:-未发现}"
    fi

    memory_lines=$(server_cat_overview_memory)
    memory_usage=$(printf '%s\n' "$memory_lines" | sed -n '1p')
    swap_usage=$(printf '%s\n' "$memory_lines" | sed -n '2p')

    if command -v systemctl > /dev/null 2>&1; then
        failed_services=$(systemctl --failed --no-legend --plain 2>/dev/null | server_cat_overview_nonempty_line_count)
    fi
    if command -v ss > /dev/null 2>&1; then
        listening_ports=$(ss -H -lntu 2>/dev/null | server_cat_overview_nonempty_line_count)
    fi

    print_step "服务器概览"
    server_cat_overview_row "主机" "$host_name"
    server_cat_overview_row "系统" "$os_name"
    server_cat_overview_row "内核" "$(uname -r 2>/dev/null || printf '未知')"
    server_cat_overview_row "运行时间" "$uptime_text"
    server_cat_overview_row "系统时间" "$(date '+%F %T %Z')"
    server_cat_overview_row "内网地址" "$private_ip"
    server_cat_overview_row "CPU" "$cpu_count 核，负载 $load_average"
    server_cat_overview_row "内存" "${memory_usage:-无法读取}"
    server_cat_overview_row "Swap" "${swap_usage:-未配置}"
    server_cat_overview_row "根分区" "$(server_cat_overview_disk space)"
    server_cat_overview_row "根分区 inode" "$(server_cat_overview_disk inode)"
    server_cat_overview_row "Docker" "$(server_cat_overview_docker)"
    server_cat_overview_row "失败服务" "$failed_services"
    server_cat_overview_row "监听端口" "$listening_ports"
    if [[ -e "$reboot_required_file" ]]; then
        server_cat_overview_row "系统重启" "需要"
    else
        server_cat_overview_row "系统重启" "不需要"
    fi
    server_cat_overview_row "Agent 定时器" "$(server_cat_overview_agent_timer)"
}
