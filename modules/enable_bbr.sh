#!/bin/bash

MENU_NAME="开启 BBR 优化"
MENU_FUNC="enable_bbr"
ROLLBACK_FUNC="rollback_bbr"
PRIORITY=50

function enable_bbr() {
    print_step "🚀 开启 TCP BBR 拥塞控制算法..."

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
    local backup_file="/etc/sysctl.conf.backup.$(date +%Y%m%d_%H%M%S)"

    # 备份原配置
    if [ -f "$sysctl_file" ] && [ ! -f "$sysctl_file.bbr_backup" ]; then
        cp "$sysctl_file" "$sysctl_file.bbr_backup"
        print_info "✓ 已备份原配置到 $sysctl_file.bbr_backup"
    fi

    # 移除旧的 BBR 配置（如果存在）
    sed -i '/net\.core\.default_qdisc=fq/d' "$sysctl_file" 2>/dev/null || true
    sed -i '/net\.ipv4\.tcp_congestion_control=bbr/d' "$sysctl_file" 2>/dev/null || true

    # 添加 BBR 配置
    cat >> "$sysctl_file" << EOF

# TCP BBR 拥塞控制算法
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    # 应用配置
    sysctl -p > /dev/null 2>&1
    sysctl net.core.default_qdisc=fq > /dev/null 2>&1
    sysctl net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1

    # 验证 BBR 已开启
    local current_qdisc=$(sysctl -n net.core.default_qdisc)
    local current_congestion=$(sysctl -n net.ipv4.tcp_congestion_control)

    echo ""
    print_success "✅ BBR 已开启！"
    echo ""
    print_info "📊 当前配置："
    echo "  • 默认队列调度: $current_qdisc"
    echo "  • 拥塞控制算法: $current_congestion"
    echo ""

    # 验证
    if [[ "$current_congestion" == "bbr" ]]; then
        print_success "✓ BBR 拥塞控制已生效"
    else
        print_warning "⚠ BBR 可能未生效，请重启服务器后验证"
    fi

    if [[ "$current_qdisc" == "fq" ]]; then
        print_success "✓ FQ 队列调度已生效"
    else
        print_warning "⚠ FQ 队列调度可能未生效"
    fi

    echo ""
    print_info "📝 验证命令："
    echo "  sysctl net.core.default_qdisc"
    echo "  sysctl net.ipv4.tcp_congestion_control"
    echo ""
    print_info "📝 如需恢复默认配置，请运行："
    echo "  sudo cp /etc/sysctl.conf.bbr_backup /etc/sysctl.conf"
    echo "  sudo sysctl -p"

    return 0
}

function rollback_bbr() {
    print_step "↩️  恢复 BBR 配置..."

    local sysctl_file="/etc/sysctl.conf"
    local backup_file="$sysctl_file.bbr_backup"
    local modules_file="/etc/modules-load.d/bbr.conf"

    # 移除 BBR 配置
    sed -i '/net\.core\.default_qdisc=fq/d' "$sysctl_file" 2>/dev/null || true
    sed -i '/net\.ipv4\.tcp_congestion_control=bbr/d' "$sysctl_file" 2>/dev/null || true

    # 恢复备份配置（如果存在）
    if [ -f "$backup_file" ]; then
        cp "$backup_file" "$sysctl_file"
        print_info "✓ 已恢复 sysctl 配置"
    fi

    # 删除模块加载配置
    rm -f "$modules_file"

    # 应用默认配置
    sysctl net.core.default_qdisc=fq_codel > /dev/null 2>&1
    sysctl net.ipv4.tcp_congestion_control=cubic > /dev/null 2>&1

    # 卸载 BBR 模块
    modprobe -r tcp_bbr 2>/dev/null || true

    # 显示当前配置
    local current_qdisc=$(sysctl -n net.core.default_qdisc)
    local current_congestion=$(sysctl -n net.ipv4.tcp_congestion_control)

    echo ""
    print_success "✅ BBR 配置已恢复默认值"
    print_info "当前配置："
    echo "  • 默认队列调度: $current_qdisc"
    echo "  • 拥塞控制算法: $current_congestion"

    return 0
}
