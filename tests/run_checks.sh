#!/bin/bash
# 不执行服务器操作，仅验证脚本结构与可安全加载性。

set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_COUNT=0
FAIL_COUNT=0

pass() {
    CHECK_COUNT=$((CHECK_COUNT + 1))
    printf 'PASS %s\n' "$1"
}

fail() {
    CHECK_COUNT=$((CHECK_COUNT + 1))
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL %s\n' "$1" >&2
}

assert_contains() {
    local file="$1"
    local pattern="$2"
    local description="$3"

    if rg -q -- "$pattern" "$PROJECT_ROOT/$file"; then
        pass "$description"
    else
        fail "$description"
    fi
}

assert_not_contains() {
    local file="$1"
    local pattern="$2"
    local description="$3"

    if rg -q -- "$pattern" "$PROJECT_ROOT/$file"; then
        fail "$description"
    else
        pass "$description"
    fi
}

assert_contains_literal() {
    local file="$1"
    local text="$2"
    local description="$3"

    if rg -Fq -- "$text" "$PROJECT_ROOT/$file"; then
        pass "$description"
    else
        fail "$description"
    fi
}

check_syntax() {
    if bash -n "$@"; then
        pass "全部 Bash 脚本语法有效"
    else
        fail "全部 Bash 脚本语法有效"
    fi
}

check_menu_metadata() {
    local script
    local function_name

    for script in "$PROJECT_ROOT"/modules/*.sh "$PROJECT_ROOT"/softwares/*.sh "$PROJECT_ROOT"/configs/*.sh; do
        function_name=$(awk -F'"' '/^MENU_FUNC=/{print $2; exit}' "$script")

        if [[ -z "$function_name" ]]; then
            fail "$(basename "$script") 声明 MENU_FUNC"
        elif rg -q "^function $function_name\(\)" "$script"; then
            pass "$(basename "$script") 的 MENU_FUNC 可调用"
        else
            fail "$(basename "$script") 的 MENU_FUNC 可调用"
        fi
    done
}

check_source_safety() {
    local script

    for script in backups/backup_menu.sh backups/create_backup.sh backups/restore_backup.sh; do
        if bash -c 'set +e; source "$1"; case "$-" in *e*) exit 1 ;; *) exit 0 ;; esac' _ "$PROJECT_ROOT/$script"; then
            pass "$script source 后不启用 errexit"
        else
            fail "$script source 后不启用 errexit"
        fi
    done
}

check_utils_behavior() {
    if bash -c 'source "$1"; is_number 42 && ! is_number 4a && function_exists is_number' _ "$PROJECT_ROOT/lib/utils.sh"; then
        pass "公共输入和函数校验可用"
    else
        fail "公共输入和函数校验可用"
    fi

    if bash -c 'source "$1"; missing_menu_function() { return 0; }; call_menu_func missing_menu_function' _ "$PROJECT_ROOT/lib/utils.sh"; then
        pass "菜单函数通过公共调用器执行"
    else
        fail "菜单函数通过公共调用器执行"
    fi
}

check_release_behavior() {
    if bash "$PROJECT_ROOT/tests/release_checks.sh"; then
        pass "签名发布源检查验证有效清单并拒绝路径穿越"
    else
        fail "签名发布源检查验证有效清单并拒绝路径穿越"
    fi
}

check_completion_behavior() {
    if bash -c 'source "$1"; COMP_WORDS=(scat agent ""); COMP_CWORD=2; _scat_completion; [[ " ${COMPREPLY[*]} " == *" check "* && " ${COMPREPLY[*]} " == *" status "* ]]' _ "$PROJECT_ROOT/packaging/completions/scat.bash"; then
        pass "scat 补全提供 Agent 子命令"
    else
        fail "scat 补全提供 Agent 子命令"
    fi

    if bash -c 'source "$1"; COMP_WORDS=(scat update ""); COMP_CWORD=2; _scat_completion; [[ " ${COMPREPLY[*]} " == *" rollback "* ]]' _ "$PROJECT_ROOT/packaging/completions/scat.bash"; then
        pass "scat 补全提供更新子命令"
    else
        fail "scat 补全提供更新子命令"
    fi
}

check_platform_behavior() {
    if bash "$PROJECT_ROOT/tests/platform_checks.sh"; then
        pass "发行版兼容层识别支持范围并拒绝未验证系统"
    else
        fail "发行版兼容层识别支持范围并拒绝未验证系统"
    fi
}

check_syntax \
    "$PROJECT_ROOT/main.sh" \
    "$PROJECT_ROOT"/lib/*.sh \
    "$PROJECT_ROOT/packaging/install.sh" \
    "$PROJECT_ROOT"/modules/*.sh \
    "$PROJECT_ROOT"/softwares/*.sh \
    "$PROJECT_ROOT"/configs/*.sh \
    "$PROJECT_ROOT"/backups/*.sh \
    "$PROJECT_ROOT"/scripts/*.sh
check_menu_metadata
check_source_safety
check_utils_behavior
check_release_behavior
check_completion_behavior
check_platform_behavior

assert_not_contains "configs/check_update.sh" 'reset --hard' "自更新不强制丢弃本地修改"
assert_not_contains "configs/check_update.sh" 'git -C' "生产更新不再依赖 Git 仓库"
assert_contains_literal "configs/check_update.sh" 'server_cat_update_check' "菜单检查更新复用签名发布源"
assert_contains_literal "main.sh" 'dispatch_command "$@"' "主入口在菜单前分发子命令"
assert_contains_literal "packaging/install.sh" 'for command_name in scat server-cat' "首次安装提供 scat 与兼容命令"
assert_contains_literal "lib/release.sh" 'for command_name in scat server-cat' "更新安装提供 scat 与兼容命令"
assert_contains_literal "scripts/build-release.sh" 'packaging/completions/scat.bash' "发布包包含 scat 补全规则"
assert_contains_literal "packaging/install.sh" 'bash-completion' "首次安装部署 Bash 补全"
assert_contains_literal "lib/release.sh" 'bash-completion' "更新安装部署 Bash 补全"
assert_contains_literal "lib/release.sh" 'gpgv --keyring' "更新检查使用独立公钥验证签名"
assert_contains_literal "lib/release.sh" "--proto '=https'" "更新检查仅允许 HTTPS 发布源"
assert_contains "lib/backup_tools.sh" 'get_real_home' "默认备份目录使用实际用户主目录"
assert_contains "modules/ssh_config.sh" 'restart_ssh_service' "SSH 配置复用服务重启回退"
assert_contains "backups/restore_backup.sh" 'restart_ssh_service' "SSH 恢复复用服务重启回退"
assert_contains_literal "main.sh" 'is_number "$choice"' "菜单在数值比较前校验输入"
assert_contains_literal "main.sh" 'call_menu_func "$func"' "菜单通过安全调用器执行功能"
assert_contains "backups/restore_backup.sh" 'get_real_home' "恢复用户数据使用实际用户主目录"
assert_contains_literal "backups/restore_backup.sh" 'fail_count=$((fail_count + 1))' "全部恢复会汇总子项失败"
assert_contains "modules/init_user_dirs.sh" 'get_real_home' "用户目录初始化使用实际用户主目录"
assert_contains "modules/certbot_renew.sh" 'get_real_home' "证书续期使用实际用户主目录"
printf '\n检查完成：%s 项，失败 %s 项。\n' "$CHECK_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -ne 0 ]]; then
    exit 1
fi
