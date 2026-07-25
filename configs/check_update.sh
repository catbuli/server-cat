#!/bin/bash

MENU_NAME="检查更新"
MENU_FUNC="check_update"
PRIORITY=10

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"

function check_update() {
    print_step "🔄 检查更新..."

    local project_root="$(cd "$SCRIPT_DIR/.." && pwd)"
    local repo_owner
    local git_user
    local worktree_status
    local current_branch
    local commit_count

    repo_owner=$(stat -f '%Su' "$project_root/.git" 2>/dev/null || stat -c '%U' "$project_root/.git" 2>/dev/null)
    git_user="${SUDO_USER:-$repo_owner}"

    if [[ -z "$git_user" ]]; then
        print_error "无法确定仓库所属用户"
        return 1
    fi

    run_git() {
        if [[ $EUID -eq 0 ]] && [[ "$git_user" != "root" ]]; then
            sudo -u "$git_user" git -C "$project_root" "$@"
        else
            git -C "$project_root" "$@"
        fi
    }

    print_info "正在检查远程更新..."

    if ! worktree_status=$(run_git status --porcelain 2>&1); then
        print_error "检查工作区状态失败: $worktree_status"
        return 1
    fi

    if [[ -n "$worktree_status" ]]; then
        print_warning "检测到未提交修改，已取消更新以保护本地内容"
        return 1
    fi

    current_branch=$(run_git branch --show-current 2>&1)
    if [[ -z "$current_branch" ]]; then
        print_error "当前不在可更新的 Git 分支上"
        return 1
    fi

    if ! run_git fetch origin -q; then
        print_error "获取远程更新失败"
        return 1
    fi

    if ! run_git show-ref --verify --quiet "refs/remotes/origin/$current_branch"; then
        print_error "远程不存在分支: origin/$current_branch"
        return 1
    fi

    commit_count=$(run_git rev-list --count "HEAD..origin/$current_branch" 2>&1)
    if ! is_number "$commit_count"; then
        print_error "计算更新数量失败: $commit_count"
        return 1
    fi

    if [[ "$commit_count" == "0" ]]; then
        print_success "✅ 已经是最新版本"
        echo ""
        return 0
    fi

    print_success "📦 发现 $commit_count 个新提交"
    echo ""
    print_info "最新提交："
    run_git log --oneline -5 "HEAD..origin/$current_branch" 2>/dev/null | while read -r line; do
        echo "  • $line"
    done
    echo ""

    if confirm "是否立即更新?" "y"; then
        print_step "正在同步远程版本..."
        if run_git pull --ff-only origin "$current_branch"; then
            print_success "✅ 更新成功，正在重启..."
            sleep 1
            exec "$project_root/main.sh"
        else
            print_error "✗ 更新失败"
            return 1
        fi
    fi

    return 0
}
