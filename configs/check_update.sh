#!/bin/bash

MENU_NAME="检查更新"
MENU_FUNC="check_update"
PRIORITY=10

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"

function check_update() {
    print_step "🔄 检查更新..."

    local project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local repo_owner=$(stat -f '%Su' "$project_root/.git" 2>/dev/null || stat -c '%U' "$project_root/.git" 2>/dev/null)
    local git_user="${SUDO_USER:-$repo_owner}"

    print_info "正在检查远程更新..."

    local check_result=$(sudo -u "$git_user" bash -c "
        cd '$project_root' || exit 1
        current_branch=\$(git branch --show-current 2>/dev/null) || exit 1
        git fetch origin -q 2>/dev/null || exit 1
        commit_count=\$(git rev-list --count HEAD..origin/\$current_branch 2>/dev/null || echo '0')
        echo \"\$current_branch|\$commit_count\"
    " 2>&1)

    if [[ $? -ne 0 ]]; then
        print_error "检查更新失败: $check_result"
        return 1
    fi

    local current_branch=$(echo "$check_result" | cut -d'|' -f1)
    local commit_count=$(echo "$check_result" | cut -d'|' -f2)

    if [[ "$commit_count" == "0" ]]; then
        print_success "✅ 已经是最新版本"
        echo ""
        return 0
    fi

    print_success "📦 发现 $commit_count 个新提交"

    if confirm "是否立即更新?" "y"; then
        print_step "正在同步远程版本..."
        sudo -u "$git_user" git -C "$project_root" fetch origin && \
        sudo -u "$git_user" git -C "$project_root" reset --hard "origin/$current_branch" && \
        print_success "✅ 更新成功" || print_error "✗ 更新失败"
    fi

    return 0
}
