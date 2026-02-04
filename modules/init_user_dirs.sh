#!/bin/bash

MENU_NAME="初始化用户目录"
MENU_FUNC="init_user_dirs"
ROLLBACK_FUNC="rollback_init_user_dirs"
PRIORITY=30

function init_user_dirs() {
    print_step "📁 初始化用户常用目录..."

    HOME_DIR="${HOME_DIR:-$HOME}"
    DIRS=("logs" "dockers" "configs" "scripts")

    print_info "目标位置: $HOME_DIR"

    # 创建目录
    for dir in "${DIRS[@]}"; do
        full_path="$HOME_DIR/$dir"

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
    for dir in "${DIRS[@]}"; do
        full_path="$HOME_DIR/$dir"
        if [ -d "$full_path" ]; then
            echo "  - $full_path"
        fi
    done
}

function rollback_init_user_dirs() {
    print_step "↩️  恢复用户目录..."

    HOME_DIR="${HOME_DIR:-$HOME}"
    DIRS=("logs" "dockers" "configs" "scripts" "backups")

    print_info "将删除以下目录（如果为空）："
    for dir in "${DIRS[@]}"; do
        full_path="$HOME_DIR/$dir"
        if [ -d "$full_path" ]; then
            echo "  - $full_path"
        fi
    done

    print_warning "⚠️  仅删除空目录，有内容的目录会保留"
    read -p "确认继续? (y/n): " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        for dir in "${DIRS[@]}"; do
            full_path="$HOME_DIR/$dir"
            if [ -d "$full_path" ]; then
                # 只删除空目录
                rmdir "$full_path" 2>/dev/null && print_info "✓ 已删除: $full_path"
            fi
        done
        print_success "✅ 用户目录恢复完成"
    else
        print_warning "已取消恢复"
    fi
}
