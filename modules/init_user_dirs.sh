#!/bin/bash

MENU_NAME="初始化用户目录"
MENU_FUNC="init_user_dirs"
ROLLBACK_FUNC="rollback_init_user_dirs"
PRIORITY=30

MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$MODULES_DIR/../lib/utils.sh"

function init_user_dirs() {
    print_step "📁 初始化用户常用目录..."

    local user_home="${HOME_DIR:-$(get_real_home)}"
    local dirs=("logs" "dockers" "configs" "scripts")
    local dir
    local full_path

    print_info "目标位置: $user_home"

    # 创建目录
    for dir in "${dirs[@]}"; do
        full_path="$user_home/$dir"

        if [ -d "$full_path" ]; then
            print_info "✓ $dir 目录已存在"
        else
            mkdir -p "$full_path"
            if [ $? -eq 0 ]; then
                print_success "✓ 已创建: $full_path"
            else
                print_error "✗ 创建失败: $full_path"
            fi
        fi
    done

    print_success "✅ 目录初始化完成"

    # 显示创建的目录列表
    print_info "📋 已创建的目录："
    for dir in "${dirs[@]}"; do
        full_path="$user_home/$dir"
        if [ -d "$full_path" ]; then
            echo "  - $full_path"
        fi
    done
}

function rollback_init_user_dirs() {
    print_step "↩️  恢复对用户目录的修改..."

    local user_home="${HOME_DIR:-$(get_real_home)}"
    local dirs=("logs" "dockers" "configs" "scripts")
    local dir
    local full_path

    print_info "将删除以下目录（如果为空）："
    for dir in "${dirs[@]}"; do
        full_path="$user_home/$dir"
        if [ -d "$full_path" ]; then
            echo "  - $full_path"
        fi
    done

    print_warning "⚠️  仅删除空目录，有内容的目录会保留"

    if confirm "确认继续"; then
        for dir in "${dirs[@]}"; do
            full_path="$user_home/$dir"
            if [ -d "$full_path" ]; then
                rmdir "$full_path" 2>/dev/null && print_info "✓ 已删除: $full_path"
            fi
        done
        print_success "✅ 用户目录已恢复"
    else
        print_warning "已取消恢复"
    fi
}
