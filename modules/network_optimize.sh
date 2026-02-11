#!/bin/bash

MENU_NAME="网络优化设置"
MENU_FUNC="network_optimize"
ROLLBACK_FUNC="rollback_network"
PRIORITY=50

function network_optimize() {
    print_step "🚀 开启网络优化（BBR + ECN）..."

    # 检查内核版本
    local kernel_version=$(uname -r | cut -d. -f1-2)
    local kernel_major=$(uname -r | cut -d. -f1)
    local kernel_minor=$(uname -r | cut -d. -f2)

    if [[ "$kernel_major" -lt 4 ]] || [[ "$kernel_major" -eq 4 && "$kernel_minor" -lt 9 ]]; then
        print_error "内核版本过低 ($kernel_version)，BBR 需要 4.9+ 内核"
        return 1
    fi
    print_info "✓ 内核版本: $kernel_version (支持 BBR)"

    # 检查 BBR 是否可用
    if ! modinfo tcp_bbr &>/dev/null; then
        print_error "BBR 模块不可用"
        return 1
    fi
    print_info "✓ BBR 模块可用"

    # 加载 BBR 模块
    modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null || true

    # 配置 sysctl
    local sysctl_file="/etc/sysctl.conf"

    if [ -f "$sysctl_file" ] && [ ! -f "$sysctl_file.network_backup" ]; then
        cp "$sysctl_file" "$sysctl_file.network_backup"
        print_info "✓ 已备份原配置到 $sysctl_file.network_backup"
    fi

    # 移除旧的网络优化配置
    sed -i '/net\.core\.default_qdisc=fq/d' "$sysctl_file" 2>/dev/null || true
    sed -i '/net\.ipv4\.tcp_congestion_control=bbr/d' "$sysctl_file" 2>/dev/null || true
    sed -i '/net\.ipv4\.tcp_ecn=/d' "$sysctl_file" 2>/dev/null || true
    sed -i '/# 网络优化配置/d' "$sysctl_file" 2>/dev/null || true

    # 添加网络优化配置
    cat >> "$sysctl_file" << EOF

# 网络优化配置 (BBR + ECN)
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_ecn=1
EOF

    # 应用配置
    sysctl -p > /dev/null 2>&1
    sysctl net.core.default_qdisc=fq > /dev/null 2>&1
    sysctl net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1
    sysctl net.ipv4.tcp_ecn=1 > /dev/null 2>&1

    # 验证配置
    local current_qdisc=$(sysctl -n net.core.default_qdisc)
    local current_congestion=$(sysctl -n net.ipv4.tcp_congestion_control)
    local current_ecn=$(sysctl -n net.ipv4.tcp_ecn)

    echo ""
    print_success "✅ 网络优化已开启！"
    echo ""
    print_info "📊 当前配置："
    echo "  • 队列调度: $current_qdisc"
    echo "  • 拥塞控制: $current_congestion"
    echo "  • ECN: $current_ecn"
    echo ""

    [[ "$current_congestion" == "bbr" ]] && print_success "✓ BBR 拥塞控制已生效" || print_warning "⚠ BBR 可能未生效"
    [[ "$current_qdisc" == "fq" ]] && print_success "✓ FQ 队列调度已生效" || print_warning "⚠ FQ 可能未生效"
    [[ "$current_ecn" == "1" ]] && print_success "✓ ECN 已启用" || print_warning "⚠ ECN 可能未生效"

    echo ""
    print_info "📝 验证命令："
    echo "  sysctl net.core.default_qdisc"
    echo "  sysctl net.ipv4.tcp_congestion_control"
    echo "  sysctl net.ipv4.tcp_ecn"

    return 0
}

function rollback_network() {
    print_step "↩️  恢复网络优化设置..."

    local sysctl_file="/etc/sysctl.conf"
    local modules_file="/etc/modules-load.d/bbr.conf"

    # 移除网络优化配置
    sed -i '/net\.core\.default_qdisc=fq/d' "$sysctl_file" 2>/dev/null || true
    sed -i '/net\.ipv4\.tcp_congestion_control=bbr/d' "$sysctl_file" 2>/dev/null || true
    sed -i '/net\.ipv4\.tcp_ecn=/d' "$sysctl_file" 2>/dev/null || true
    sed -i '/# 网络优化配置/d' "$sysctl_file" 2>/dev/null || true

    # 恢复备份配置
    if [ -f "$sysctl_file.network_backup" ]; then
        cp "$sysctl_file.network_backup" "$sysctl_file"
        rm -f "$sysctl_file.network_backup"
        print_info "✓ 已恢复 sysctl 配置"
    fi

    # 删除模块加载配置
    rm -f "$modules_file"

    # 应用默认配置
    sysctl net.core.default_qdisc=fq_codel > /dev/null 2>&1
    sysctl net.ipv4.tcp_congestion_control=cubic > /dev/null 2>&1
    sysctl net.ipv4.tcp_ecn=0 > /dev/null 2>&1

    # 卸载 BBR 模块
    modprobe -r tcp_bbr 2>/dev/null || true

    # 显示当前配置
    local current_qdisc=$(sysctl -n net.core.default_qdisc)
    local current_congestion=$(sysctl -n net.ipv4.tcp_congestion_control)
    local current_ecn=$(sysctl -n net.ipv4.tcp_ecn)

    echo ""
    print_success "✅ 网络优化已恢复默认值"
    print_info "当前配置："
    echo "  • 队列调度: $current_qdisc"
    echo "  • 拥塞控制: $current_congestion"
    echo "  • ECN: $current_ecn"

    return 0
}
