#!/bin/bash

MENU_NAME="命令行工具"
MENU_FUNC="cli_menu"
PRIORITY=20

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"

function press_enter_to_continue() {
    print_step "请按 [Enter] 键继续..."
    read
}

function install_cli() {
    print_step "🔗 安装命令行工具..."

    # 获取实际用户信息
    local real_user=$(get_real_user)
    local real_home=$(get_real_home)
    local bin_dir="$real_home/.local/bin"
    local link_name="server-cat"
    local target_script="$SCRIPT_DIR/../main.sh"

    print_info "安装用户: $real_user"
    print_info "安装目录: $bin_dir"
    echo ""

    # 检查 main.sh 是否存在
    if [[ ! -f "$target_script" ]]; then
        print_error "主脚本不存在: $target_script"
        return 1
    fi

    # 创建 .local/bin 目录（以实际用户权限）
    sudo -u "$real_user" mkdir -p "$bin_dir"

    # 删除旧的链接（如果存在）
    if [[ -L "$bin_dir/$link_name" ]] || [[ -f "$bin_dir/$link_name" ]]; then
        sudo -u "$real_user" rm -f "$bin_dir/$link_name"
        print_info "✓ 移除旧文件"
    fi

    # 创建符号链接（以实际用户权限）
    sudo -u "$real_user" ln -s "$target_script" "$bin_dir/$link_name"
    
    if [[ ! -L "$bin_dir/$link_name" ]]; then
        print_error "创建符号链接失败"
        return 1
    fi
    
    print_success "✓ 已创建符号链接"

    # 添加到 PATH（如果还没有）
    local bashrc="$real_home/.bashrc"
    local path_line='export PATH="$HOME/.local/bin:$PATH"'
    
    # 检查 .bashrc 是否存在，不存在则创建
    if [[ ! -f "$bashrc" ]]; then
        sudo -u "$real_user" touch "$bashrc"
    fi
    
    # 检查是否已经添加了 PATH
    if ! sudo -u "$real_user" grep -q '.local/bin' "$bashrc" 2>/dev/null; then
        print_info "添加 .local/bin 到 PATH..."
        sudo -u "$real_user" bash -c "echo '' >> '$bashrc'"
        sudo -u "$real_user" bash -c "echo '# Added by server-cat' >> '$bashrc'"
        sudo -u "$real_user" bash -c "echo '$path_line' >> '$bashrc'"
        print_success "✓ 已更新 .bashrc"
    else
        print_info "✓ PATH 已配置"
    fi

    echo ""
    print_success "✅ 命令行工具安装成功！"
    echo ""
    print_info "📝 使用方法："
    echo "  server-cat              # 启动工具（需要 sudo 权限）"
    echo "  sudo server-cat         # 或者直接使用 sudo"
    echo ""
    print_info "📍 安装位置: $bin_dir/$link_name"
    echo ""
    print_warning "⚠️  首次使用需要执行以下命令使 PATH 生效："
    print_prompt "  source ~/.bashrc"
    echo ""
    
    return 0
}

function uninstall_cli() {
    print_step "🗑️  卸载命令行工具..."

    # 获取实际用户信息
    local real_user=$(get_real_user)
    local real_home=$(get_real_home)
    local bin_dir="$real_home/.local/bin"
    local link_name="server-cat"
    local link_path="$bin_dir/$link_name"

    print_info "卸载用户: $real_user"
    echo ""

    # 检查并删除用户目录下的链接
    if [[ -L "$link_path" ]] || [[ -f "$link_path" ]]; then
        sudo -u "$real_user" rm -f "$link_path"
        print_success "✅ 已删除: $link_path"
    else
        print_info "用户目录未找到命令行工具"
    fi

    # 同时检查并删除系统目录的旧版本（兼容旧版本）
    local old_system_path="/usr/local/bin/$link_name"
    if [[ -L "$old_system_path" ]] || [[ -f "$old_system_path" ]]; then
        rm -f "$old_system_path"
        print_success "✅ 已删除旧版本: $old_system_path"
    fi

    echo ""
    print_info "💡 提示: .bashrc 中的 PATH 配置已保留，不会影响其他工具"
    
    return 0
}

function cli_menu() {
    while true; do
        local choice=$(show_menu \
            "命令行工具管理" \
            "${BLUE}" \
            "返回" \
            "安装命令行工具" "卸载命令行工具")

        case $choice in
            1)
                clear
                install_cli
                echo ""
                press_enter_to_continue
                ;;
            2)
                clear
                uninstall_cli
                echo ""
                press_enter_to_continue
                ;;
            0)
                break
                ;;
            *)
                print_error "无效输入，请重试"
                sleep 2
                ;;
        esac
    done
}
