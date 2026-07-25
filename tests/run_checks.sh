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
    local priority

    for script in "$PROJECT_ROOT"/modules/*.sh "$PROJECT_ROOT"/softwares/*.sh "$PROJECT_ROOT"/configs/*.sh; do
        function_name=$(awk -F'"' '/^MENU_FUNC=/{print $2; exit}' "$script")

        if [[ -z "$function_name" ]]; then
            fail "$(basename "$script") 声明 MENU_FUNC"
        elif rg -q "^function $function_name\(\)" "$script"; then
            pass "$(basename "$script") 的 MENU_FUNC 可调用"
        else
            fail "$(basename "$script") 的 MENU_FUNC 可调用"
        fi

        priority=$(bash -c 'source "$1/lib/utils.sh"; get_priority "$2"' _ "$PROJECT_ROOT" "$script")
        if [[ "$priority" =~ ^[0-9]+$ ]]; then
            pass "$(basename "$script") 的 PRIORITY 可解析"
        else
            fail "$(basename "$script") 的 PRIORITY 可解析"
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

    local clear_error
    clear_error=$(mktemp)
    if TERM=xterm-ghostty bash -c 'source "$1"; clear_screen' _ "$PROJECT_ROOT/lib/utils.sh" \
        > /dev/null 2> "$clear_error" && [[ ! -s "$clear_error" ]]; then
        pass "未知终端类型可静默降级清屏"
    else
        fail "未知终端类型可静默降级清屏"
    fi
    rm -f "$clear_error"
}

check_agent_command_behavior() {
    if bash -c 'source "$1/lib/utils.sh"; source "$1/lib/agent.sh"; SERVER_CAT_AGENT_BINARY=/usr/bin/true; server_cat_agent_dispatch check' _ "$PROJECT_ROOT"; then
        pass "Agent 子命令通过独立分发层执行"
    else
        fail "Agent 子命令通过独立分发层执行"
    fi

    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/lib/agent.sh"
        server_cat_agent_config_menu() { printf "%s\n" configured; }
        [[ "$(server_cat_agent_dispatch configure)" == "configured" ]]
    ' _ "$PROJECT_ROOT"; then
        pass "Agent 配置命令通过独立分发层执行"
    else
        fail "Agent 配置命令通过独立分发层执行"
    fi
}

check_agent_config_behavior() {
    local config_root
    local config_file
    local config_mode

    config_root=$(mktemp -d)
    config_file="$config_root/agent.toml"
    cp "$PROJECT_ROOT/templates/agent.toml.example" "$config_file"

    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/lib/agent_config.sh"
        config_file="$2"
        server_cat_agent_config_set "$config_file" thresholds memory_warning_percent 91 &&
            [[ "$(server_cat_agent_config_read "$config_file" thresholds memory_warning_percent)" == "91" ]] &&
            [[ "$(server_cat_agent_config_toml_array "nginx, docker")" == "[\"nginx\", \"docker\"]" ]]
    ' _ "$PROJECT_ROOT" "$config_file"; then
        pass "Agent 配置向导可安全更新字段并生成 TOML 数组"
    else
        fail "Agent 配置向导可安全更新字段并生成 TOML 数组"
    fi

    config_mode=$(stat -c '%a' "$config_file" 2>/dev/null || stat -f '%Lp' "$config_file" 2>/dev/null)
    if [[ "$config_mode" == "600" ]]; then
        pass "Agent 配置向导保持配置权限为 0600"
    else
        fail "Agent 配置向导保持配置权限为 0600"
    fi

    cp "$PROJECT_ROOT/templates/agent.toml.example" "$config_file"
    cp "$config_file" "$config_root/original.toml"
    cp "$config_file" "$config_root/staged.toml"
    server_cat_agent_config_set_for_test() {
        bash -c '
            source "$1/lib/utils.sh"
            source "$1/lib/agent_config.sh"
            SERVER_CAT_AGENT_CONFIG="$2"
            SERVER_CAT_AGENT_BINARY=/usr/bin/false
            server_cat_agent_config_set "$3" thresholds memory_warning_percent 91
            ! server_cat_agent_config_save "$3" > /dev/null 2>&1
        ' _ "$PROJECT_ROOT" "$config_file" "$config_root/staged.toml"
    }
    if server_cat_agent_config_set_for_test &&
        cmp -s "$config_file" "$config_root/original.toml" &&
        [[ ! -e "$config_root/staged.toml" ]]; then
        pass "Agent 配置校验失败时保留原配置并清理临时文件"
    else
        fail "Agent 配置校验失败时保留原配置并清理临时文件"
    fi

    rm -rf "$config_root"
}

check_release_behavior() {
    if bash "$PROJECT_ROOT/tests/release_checks.sh"; then
        pass "签名发布源检查验证有效清单并拒绝路径穿越"
    else
        fail "签名发布源检查验证有效清单并拒绝路径穿越"
    fi
}

check_legacy_layout_migration_behavior() {
    local migration_root

    migration_root=$(mktemp -d)
    mkdir -p "$migration_root/releases/0.1.0"
    printf '%s\n' "0.1.0" > "$migration_root/releases/0.1.0/VERSION"
    ln -s "releases/0.1.0" "$migration_root/current"

    if SERVER_CAT_INSTALL_ROOT="$migration_root" \
        bash -c '
            source "$1/lib/utils.sh"
            source "$1/lib/release.sh"
            server_cat_release_migrate_legacy_layout > /dev/null &&
                [[ "$SERVER_CAT_LEGACY_LAYOUT_MIGRATED" -eq 1 ]] &&
                [[ -d "$SERVER_CAT_INSTALL_ROOT/current" ]] &&
                [[ ! -L "$SERVER_CAT_INSTALL_ROOT/current" ]] &&
                [[ ! -e "$SERVER_CAT_INSTALL_ROOT/releases" ]] &&
                [[ "$(server_cat_installed_version)" == "0.1.0" ]]
        ' _ "$PROJECT_ROOT"; then
        pass "旧版发布目录可自动迁移为单一安装目录"
    else
        fail "旧版发布目录可自动迁移为单一安装目录"
    fi

    rm -rf "$migration_root"
}

check_update_menu_behavior() {
    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/configs/check_update.sh"
        server_cat_update_check() { SERVER_CAT_UPDATE_AVAILABLE=1; }
        server_cat_update_apply() { printf "%s\\n" applied; }
        confirm() { return 0; }
        [[ "$(update_server_cat)" == *"applied" ]]
    ' _ "$PROJECT_ROOT"; then
        pass "菜单更新在验签后确认并安装"
    else
        fail "菜单更新在验签后确认并安装"
    fi

    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/configs/check_update.sh"
        server_cat_update_check() { SERVER_CAT_UPDATE_AVAILABLE=1; }
        server_cat_update_apply() { exit 1; }
        confirm() { return 1; }
        update_server_cat
    ' _ "$PROJECT_ROOT" > /dev/null; then
        pass "取消菜单更新不会安装版本"
    else
        fail "取消菜单更新不会安装版本"
    fi

    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/configs/check_update.sh"
        server_cat_update_check() { SERVER_CAT_UPDATE_AVAILABLE=0; }
        server_cat_update_apply() { exit 1; }
        update_server_cat
    ' _ "$PROJECT_ROOT" > /dev/null; then
        pass "菜单在已是最新版本时不会请求安装"
    else
        fail "菜单在已是最新版本时不会请求安装"
    fi
}

check_doctor_behavior() {
    local doctor_root

    doctor_root=$(mktemp -d)
    mkdir -p "$doctor_root/install/current" "$doctor_root/etc"
    printf '%s\n' "0.1.0" > "$doctor_root/install/current/VERSION"
    printf '%s\n' '#!/bin/bash' 'exit 0' > "$doctor_root/server-cat-agent"
    chmod 0755 "$doctor_root/server-cat-agent"
    printf '%s\n' '[agent]' > "$doctor_root/etc/agent.toml"
    chmod 0600 "$doctor_root/etc/agent.toml"

    if SERVER_CAT_INSTALL_ROOT="$doctor_root/install" \
        SERVER_CAT_AGENT_BINARY="$doctor_root/server-cat-agent" \
        SERVER_CAT_AGENT_CONFIG="$doctor_root/etc/agent.toml" \
        bash -c '
            source "$1/lib/utils.sh"
            source "$1/lib/release.sh"
            source "$1/lib/doctor.sh"
            curl() { :; }
            gpgv() { :; }
            jq() { :; }
            sha256sum() { :; }
            tar() { :; }
            zstd() { :; }
            systemctl() {
                case "$1" in
                    cat) return 0 ;;
                    is-enabled) printf "%s\\n" disabled; return 0 ;;
                    is-active) printf "%s\\n" inactive; return 3 ;;
                esac
            }
            server_cat_update_check() { SERVER_CAT_UPDATE_AVAILABLE=0; }
            server_cat_doctor
        ' _ "$PROJECT_ROOT" > /dev/null; then
        pass "doctor 可验证完整运行环境"
    else
        fail "doctor 可验证完整运行环境"
    fi

    rm -rf "$doctor_root"
}

check_config_source_behavior() {
    if bash -c '
        source_dir="/server-cat-root"
        SCRIPT_DIR="$source_dir"
        source "$1/configs/check_update.sh"
        source "$1/configs/doctor.sh"
        source "$1/configs/cleanup.sh"
        source "$1/configs/agent_config.sh"
        [[ "$SCRIPT_DIR" == "$source_dir" ]]
    ' _ "$PROJECT_ROOT"; then
        pass "配置菜单加载不会覆盖主入口目录"
    else
        fail "配置菜单加载不会覆盖主入口目录"
    fi
}

check_cleanup_behavior() {
    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/lib/cleanup.sh"
        call_log="$(mktemp)"
        export SERVER_CAT_CLEANUP_CALL_LOG="$call_log"
        systemd-tmpfiles() { printf "%s\\n" "$*" >> "$SERVER_CAT_CLEANUP_CALL_LOG"; }
        confirm() { return 0; }
        server_cat_cleanup_temp > /dev/null &&
            grep -Fx -- "--clean --dry-run" "$call_log" > /dev/null &&
            grep -Fx -- "--clean" "$call_log" > /dev/null
    ' _ "$PROJECT_ROOT"; then
        pass "临时文件清理先检查再按系统规则执行"
    else
        fail "临时文件清理先检查再按系统规则执行"
    fi

    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/lib/cleanup.sh"
        docker() { printf "%s\\n" "$*"; }
        confirm_strong() { [[ "$1" == "CLEAN" ]]; }
        output="$(server_cat_cleanup_docker_dangling_images)"
        [[ "$output" == *"image prune --force"* && "$output" != *"volume prune"* && "$output" != *"system prune"* ]]
    ' _ "$PROJECT_ROOT"; then
        pass "Docker 镜像清理不涉及卷或全量清理"
    else
        fail "Docker 镜像清理不涉及卷或全量清理"
    fi
}

check_completion_behavior() {
    if bash -c 'source "$1"; COMP_WORDS=(scat agent ""); COMP_CWORD=2; _scat_completion; [[ " ${COMPREPLY[*]} " == *" check "* && " ${COMPREPLY[*]} " == *" status "* && " ${COMPREPLY[*]} " == *" configure "* && " ${COMPREPLY[*]} " == *" test-email "* && " ${COMPREPLY[*]} " == *" mute "* && " ${COMPREPLY[*]} " == *" unmute "* ]]' _ "$PROJECT_ROOT/packaging/completions/scat.bash"; then
        pass "scat 补全提供 Agent 子命令"
    else
        fail "scat 补全提供 Agent 子命令"
    fi

    if bash -c 'source "$1"; COMP_WORDS=(scat update ""); COMP_CWORD=2; _scat_completion; [[ " ${COMPREPLY[*]} " == *" rollback "* ]]' _ "$PROJECT_ROOT/packaging/completions/scat.bash"; then
        fail "scat 补全不再提供回退命令"
    else
        pass "scat 补全不再提供回退命令"
    fi

    if bash -c 'source "$1"; COMP_WORDS=(scat update ""); COMP_CWORD=2; _scat_completion; [[ " ${COMPREPLY[*]} " == *" check "* && " ${COMPREPLY[*]} " == *" apply "* ]]' _ "$PROJECT_ROOT/packaging/completions/scat.bash"; then
        pass "scat 补全提供检查与安装更新命令"
    else
        fail "scat 补全提供检查与安装更新命令"
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
check_agent_command_behavior
check_agent_config_behavior
check_release_behavior
check_legacy_layout_migration_behavior
check_update_menu_behavior
check_doctor_behavior
check_config_source_behavior
check_cleanup_behavior
check_completion_behavior
check_platform_behavior

assert_not_contains "configs/check_update.sh" 'reset --hard' "自更新不强制丢弃本地修改"
assert_not_contains "configs/check_update.sh" 'git -C' "生产更新不再依赖 Git 仓库"
assert_contains_literal "configs/check_update.sh" 'server_cat_update_check' "菜单更新复用签名发布源"
assert_contains_literal "configs/check_update.sh" 'server_cat_update_apply' "菜单更新可安装已验证版本"
assert_contains_literal "configs/check_update.sh" 'confirm "已完成更新验证，是否立即安装"' "菜单更新安装前要求确认"
assert_contains_literal "configs/doctor.sh" 'server_cat_doctor' "菜单提供运行环境检查"
assert_contains_literal "configs/cleanup.sh" 'server_cat_cleanup_menu' "菜单提供空间清理"
assert_contains_literal "configs/agent_config.sh" 'server_cat_agent_config_menu' "菜单提供 Agent 配置向导"
assert_contains_literal "main.sh" 'scat doctor' "命令行提供运行环境检查"
assert_contains_literal "main.sh" 'scat agent configure' "命令行提供 Agent 配置向导"
assert_contains_literal "lib/cleanup.sh" 'systemd-tmpfiles --clean' "临时文件清理使用系统规则"
assert_not_contains "lib/cleanup.sh" 'docker volume prune' "空间清理不删除 Docker 卷"
assert_not_contains "lib/cleanup.sh" 'docker system prune' "空间清理不执行 Docker 全量清理"
assert_not_contains "README.md" 'update rollback' "用户文档不再提供版本回退"
assert_not_contains "main.sh" 'server_cat_update_rollback' "命令行不再保留版本回退"
assert_not_contains "packaging/completions/scat.bash" 'rollback' "补全不再包含版本回退"
assert_not_contains "lib/release.sh" 'server_cat_update_rollback' "在线更新不再保留版本回退"
assert_contains_literal "main.sh" 'dispatch_command "$@"' "主入口在菜单前分发子命令"
assert_contains_literal "main.sh" 'server_cat_agent_dispatch "${@:2}"' "主入口委托 Agent 子命令分发"
assert_contains_literal "packaging/install.sh" 'for command_name in scat server-cat' "首次安装提供 scat 与兼容命令"
assert_contains_literal "lib/release.sh" 'for command_name in scat server-cat' "更新安装提供 scat 与兼容命令"
assert_contains_literal "scripts/build-release.sh" 'packaging/completions/scat.bash' "发布包包含 scat 补全规则"
assert_contains_literal "scripts/build-release.sh" 'main.sh lib configs templates backups modules softwares scripts' "发布包包含运行配置模板"
assert_contains_literal "packaging/install.sh" 'bash-completion' "首次安装部署 Bash 补全"
assert_contains_literal "lib/release.sh" 'bash-completion' "更新安装部署 Bash 补全"
assert_contains_literal "packaging/install.sh" 'templates/agent.toml.example' "首次安装从模板创建 Agent 配置"
assert_contains_literal "lib/release.sh" 'templates/agent.toml.example' "更新从模板创建 Agent 配置"
assert_not_contains "packaging/install.sh" 'smtp.env' "首次安装不再创建独立 SMTP 配置"
assert_not_contains "lib/release.sh" 'smtp.env' "更新不再创建独立 SMTP 配置"
assert_not_contains "packaging/systemd/server-cat-agent.service" 'EnvironmentFile' "Agent 服务不依赖独立 SMTP 配置"
assert_contains_literal "templates/agent.toml.example" 'smtp_host = ""' "Agent 模板包含 SMTP 配置"
assert_contains_literal "lib/release.sh" 'gpgv --keyring' "更新检查使用独立公钥验证签名"
assert_contains_literal "lib/release.sh" "--proto '=https'" "更新检查仅允许 HTTPS 发布源"
assert_contains "lib/backup_tools.sh" 'get_real_home' "默认备份目录使用实际用户主目录"
assert_contains "modules/ssh_config.sh" 'restart_ssh_service' "SSH 配置复用服务重启回退"
assert_contains "backups/restore_backup.sh" 'restart_ssh_service' "SSH 恢复复用服务重启回退"
assert_contains_literal "main.sh" 'is_number "$choice"' "菜单在数值比较前校验输入"
assert_contains_literal "main.sh" 'call_menu_func "$func"' "菜单通过安全调用器执行功能"
assert_contains_literal "lib/utils.sh" 'clear_screen' "菜单使用兼容未知终端的清屏函数"
assert_contains "backups/restore_backup.sh" 'get_real_home' "恢复用户数据使用实际用户主目录"
assert_contains_literal "backups/restore_backup.sh" 'fail_count=$((fail_count + 1))' "全部恢复会汇总子项失败"
assert_contains "modules/init_user_dirs.sh" 'get_real_home' "用户目录初始化使用实际用户主目录"
assert_contains "modules/certbot_renew.sh" 'get_real_home' "证书续期使用实际用户主目录"
printf '\n检查完成：%s 项，失败 %s 项。\n' "$CHECK_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -ne 0 ]]; then
    exit 1
fi
