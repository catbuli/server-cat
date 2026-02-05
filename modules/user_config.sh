#!/bin/bash

MENU_NAME="创建 Sudo 用户"
MENU_FUNC="create_new_user"
ROLLBACK_FUNC="rollback_user_config"
PRIORITY=15

function create_new_user() {
    print_step "▶️  创建新的 Sudo 用户..."
    
    read -p "请输入新用户名: " username
    
    if id "$username" &>/dev/null; then
        print_error "错误：用户 '$username' 已存在！"
        return 1
    fi
    
    print_info "正在创建用户 '$username'..."
    adduser "$username"
    
    print_info "将用户 '$username' 添加到 sudo 组..."
    usermod -aG sudo "$username"
    
    print_success "✅ 用户 '$username' 创建成功！"
    print_success "该用户已被添加到 sudo 组，可以执行管理员命令。"
    
    print_info "用户信息："
    id "$username"

    echo ""
    print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_warning "是否需要将该用户的 sudo 设置为无需输入密码？"
    print_info "(这样在执行 sudo 命令时不需要输入密码)"

    if confirm "设置 sudo 免密码"; then
        sudoers_file="/etc/sudoers.d/$username"

        print_info "正在配置 sudo 免密码..."
        echo "$username ALL=(ALL) NOPASSWD:ALL" > "$sudoers_file"
        chmod 440 "$sudoers_file"

        if visudo -c -f "$sudoers_file" &> /dev/null; then
            print_success "✅ sudo 免密码配置成功！"
            print_success "用户 '$username' 现在可以无需密码执行 sudo 命令。"
        else
            print_error "❌ sudoers 文件语法错误，已删除配置文件。"
            rm -f "$sudoers_file"
            return 1
        fi
    else
        print_warning "已跳过 sudo 免密码配置。"
        print_info "用户 '$username' 执行 sudo 命令时需要输入密码。"
    fi
}

function rollback_user_config() {
    print_step "↩️  删除 Sudo 用户..."

    print_warning "⚠️  此操作将永久删除用户及其主目录"
    read -p "请输入要删除的用户名: " username

    if ! id "$username" &>/dev/null; then
        print_error "错误：用户 '$username' 不存在！"
        return 1
    fi

    # 二次确认
    print_warning "再次确认：确定要删除用户 '$username' 吗？"
    read -p "请输入用户名确认: " confirm

    if [[ "$confirm" != "$username" ]]; then
        print_warning "已取消删除操作"
        return 0
    fi

    # 删除 sudoers 配置文件（如果存在）
    if [ -f "/etc/sudoers.d/$username" ]; then
        rm -f "/etc/sudoers.d/$username"
        print_info "已删除 sudo 免密码配置"
    fi

    # 删除用户
    if deluser --remove-home "$username" 2>/dev/null; then
        print_success "✅ 用户 '$username' 已删除"
    else
        print_error "✗ 删除用户失败"
        return 1
    fi
}
