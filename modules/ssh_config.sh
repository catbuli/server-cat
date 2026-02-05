#!/bin/bash

MENU_NAME="配置 SSH"
MENU_FUNC="configure_ssh"
ROLLBACK_FUNC="rollback_ssh_config"
BACKUP_FUNC="backup_ssh_config"
PRIORITY=20

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"
source "$SCRIPT_DIR/../lib/backup_tools.sh"

function configure_ssh() {
    print_step "▶️  配置 SSH 服务..."

    local sshd_config="/etc/ssh/sshd_config"
    local backup_file="/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"

    print_info "备份当前 SSH 配置到: $backup_file"
    cp "$sshd_config" "$backup_file"

    print_step "[1/2] 配置 SSH 心跳包（保持连接）"

    if grep -q "^ClientAliveInterval" "$sshd_config"; then
        sed -i 's/^ClientAliveInterval.*/ClientAliveInterval 60/' "$sshd_config"
    else
        echo "ClientAliveInterval 60" >> "$sshd_config"
    fi

    if grep -q "^ClientAliveCountMax" "$sshd_config"; then
        sed -i 's/^ClientAliveCountMax.*/ClientAliveCountMax 3/' "$sshd_config"
    else
        echo "ClientAliveCountMax 3" >> "$sshd_config"
    fi

    print_success "✅ 已设置心跳包：每 60 秒发送一次，最多 3 次无响应后断开"

    print_step "[2/2] 配置密钥登录"

    read -p "请输入要配置密钥的用户名: " target_user

    if ! id "$target_user" &>/dev/null; then
        print_error "错误：用户 '$target_user' 不存在！"
        return 1
    fi

    user_home=$(eval echo ~"$target_user")
    ssh_dir="$user_home/.ssh"
    authorized_keys="$ssh_dir/authorized_keys"

    mkdir -p "$ssh_dir"
    touch "$authorized_keys"

    print_info "请粘贴公钥内容 (通常以 ssh-rsa 或 ssh-ed25519 开头)："
    print_warning "提示：粘贴后按 Enter，然后输入单独一行的 'END' 结束输入"

    public_key=""
    while IFS= read -r line; do
        if [[ "$line" == "END" ]]; then
            break
        fi
        public_key="$line"
    done

    if [[ -z "$public_key" ]]; then
        print_error "错误：公钥内容为空！"
        return 1
    fi

    if grep -qF "$public_key" "$authorized_keys" 2>/dev/null; then
        print_warning "该公钥已存在于 authorized_keys 中"
    else
        echo "$public_key" >> "$authorized_keys"
        print_success "✅ 公钥已添加到 $authorized_keys"
    fi

    chown -R "$target_user:$target_user" "$ssh_dir"
    chmod 700 "$ssh_dir"
    chmod 600 "$authorized_keys"

    print_step "是否禁用密码登录，仅允许密钥登录？"
    print_error "⚠️  警告：确保密钥配置正确后再禁用，否则可能无法登录！"

    if confirm "禁用密码登录"; then
        if grep -q "^PasswordAuthentication" "$sshd_config"; then
            sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$sshd_config"
        else
            echo "PasswordAuthentication no" >> "$sshd_config"
        fi
        print_success "✅ 已禁用密码登录，仅允许密钥认证"
    else
        print_warning "已跳过，密码登录保持启用状态"
    fi

    print_info "重启 SSH 服务使配置生效..."
    if systemctl restart sshd 2>/dev/null; then
        :
    elif systemctl restart ssh 2>/dev/null; then
        :
    else
        print_warning "SSH 服务重启失败，请手动重启"
    fi

    print_success "✅ SSH 配置完成！"
    print_info "配置摘要："
    echo "  • 心跳包间隔: 60 秒"
    echo "  • 最大心跳次数: 3 次"
    echo "  • 用户 '$target_user' 的密钥已配置"
    echo "  • 密码登录状态: $(grep "^PasswordAuthentication" "$sshd_config" | awk '{print $2}')"
    print_warning "配置备份位置: $backup_file"
}

function rollback_ssh_config() {
    print_step "↩️  恢复对 SSH 的修改..."

    local sshd_config="/etc/ssh/sshd_config"

    # 查找最新的备份文件
    local latest_backup=$(ls -t /etc/ssh/sshd_config.backup.* 2>/dev/null | head -1)

    if [[ -z "$latest_backup" ]]; then
        print_warning "未找到 SSH 配置备份，跳过恢复"
        return 0
    fi

    print_info "找到备份: $latest_backup"

    if confirm "是否恢复到此备份"; then
        cp "$latest_backup" "$sshd_config"
        systemctl restart sshd || systemctl restart ssh
        print_success "✅ SSH 配置已恢复"
        print_info "备份文件保留: $latest_backup"
    else
        print_warning "已取消恢复"
    fi
}

function backup_ssh_config() {
    local temp_dir="$1"

    backup_file "/etc/ssh/sshd_config" "$temp_dir"

    for backup in /etc/ssh/sshd_config.backup.*; do
        [ -f "$backup" ] || continue
        mkdir -p "$temp_dir/backups"
        cp "$backup" "$temp_dir/backups/"
    done
}
