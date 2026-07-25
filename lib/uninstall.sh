#!/bin/bash

# Server Cat 自身卸载逻辑。该文件会被 main.sh source，不能在顶层修改 shell 错误处理。

server_cat_uninstall_path() {
    local path="$1"
    local root="${SERVER_CAT_UNINSTALL_ROOT:-}"

    [[ "$path" == /* ]] || return 1
    if [[ -n "$root" ]]; then
        [[ "$root" == /* && "$root" != "/" && "$root" != *".."* ]] || return 1
        root="${root%/}"
    fi

    printf '%s%s\n' "$root" "$path"
}

server_cat_uninstall_command_is_managed() {
    local command_path="$1"
    local expected_main
    local resolved_target

    expected_main=$(server_cat_uninstall_path "/opt/server-cat/current/main.sh") || return 1

    if [[ -L "$command_path" ]]; then
        resolved_target=$(realpath "$command_path" 2>/dev/null || readlink -f "$command_path" 2>/dev/null || true)
        [[ "$resolved_target" == "$expected_main" ]]
        return $?
    fi

    [[ -f "$command_path" ]] || return 1
    grep -Fqx 'exec /opt/server-cat/current/main.sh "$@"' "$command_path" 2>/dev/null
}

server_cat_uninstall_stop_agent() {
    if ! command -v systemctl > /dev/null 2>&1; then
        print_warning "系统未提供 systemctl，跳过 Agent 停止检查"
        return 0
    fi

    systemctl disable --now server-cat-agent.timer > /dev/null 2>&1 || true
    systemctl stop server-cat-agent.service > /dev/null 2>&1 || true

    if systemctl is-active --quiet server-cat-agent.timer 2>/dev/null ||
        systemctl is-active --quiet server-cat-agent.service 2>/dev/null; then
        print_error "Server Cat Agent 仍在运行，已中止卸载"
        return 1
    fi

    print_info "已停止并禁用 Server Cat Agent"
    return 0
}

server_cat_uninstall_remove_file() {
    local path="$1"
    local label="$2"

    if [[ ! -e "$path" && ! -L "$path" ]]; then
        return 0
    fi

    if rm -f -- "$path"; then
        print_info "已删除 $label"
        return 0
    fi

    print_error "无法删除 $label: $path"
    return 1
}

server_cat_uninstall_remove_directory() {
    local path="$1"
    local label="$2"

    if [[ ! -e "$path" && ! -L "$path" ]]; then
        return 0
    fi

    if rm -rf -- "$path"; then
        print_info "已删除 $label"
        return 0
    fi

    print_error "无法删除 $label: $path"
    return 1
}

server_cat_uninstall_remove_command() {
    local command_path="$1"
    local command_name="$2"

    if [[ ! -e "$command_path" && ! -L "$command_path" ]]; then
        return 0
    fi

    if ! server_cat_uninstall_command_is_managed "$command_path"; then
        print_warning "跳过非 Server Cat 管理的命令: $command_path"
        return 0
    fi

    server_cat_uninstall_remove_file "$command_path" "$command_name 命令"
}

server_cat_uninstall_execute() {
    local remove_data="${1:-0}"
    local install_root
    local config_dir
    local state_dir
    local systemd_dir
    local command_dir
    local completion_file
    local failed=0
    local command_name

    [[ "$remove_data" == "0" || "$remove_data" == "1" ]] || {
        print_error "卸载数据选项无效"
        return 1
    }

    install_root=$(server_cat_uninstall_path "/opt/server-cat") || {
        print_error "卸载路径配置无效"
        return 1
    }
    config_dir=$(server_cat_uninstall_path "/etc/server-cat") || return 1
    state_dir=$(server_cat_uninstall_path "/var/lib/server-cat") || return 1
    systemd_dir=$(server_cat_uninstall_path "/etc/systemd/system") || return 1
    command_dir=$(server_cat_uninstall_path "/usr/local/sbin") || return 1
    completion_file=$(server_cat_uninstall_path "/usr/share/bash-completion/completions/scat") || return 1

    print_step "停止 Server Cat Agent..."
    server_cat_uninstall_stop_agent || return 1

    print_step "删除 Server Cat 系统集成..."
    server_cat_uninstall_remove_file \
        "$systemd_dir/server-cat-agent.service" \
        "Agent systemd 服务" || failed=1
    server_cat_uninstall_remove_file \
        "$systemd_dir/server-cat-agent.timer" \
        "Agent systemd 定时器" || failed=1
    server_cat_uninstall_remove_file \
        "$systemd_dir/timers.target.wants/server-cat-agent.timer" \
        "Agent 定时器启用链接" || failed=1

    if command -v systemctl > /dev/null 2>&1; then
        if ! systemctl daemon-reload; then
            print_error "systemd 配置重新加载失败"
            failed=1
        fi
        systemctl reset-failed server-cat-agent.service server-cat-agent.timer > /dev/null 2>&1 || true
    fi

    for command_name in scat server-cat; do
        server_cat_uninstall_remove_command \
            "$command_dir/$command_name" \
            "$command_name" || failed=1
    done
    server_cat_uninstall_remove_file "$completion_file" "scat Bash 补全" || failed=1

    print_step "删除 Server Cat 程序文件..."
    server_cat_uninstall_remove_directory "$install_root" "程序目录 $install_root" || failed=1

    if [[ "$remove_data" -eq 1 ]]; then
        print_step "删除 Server Cat 配置和状态..."
        server_cat_uninstall_remove_directory "$config_dir" "配置目录 $config_dir" || failed=1
        server_cat_uninstall_remove_directory "$state_dir" "状态目录 $state_dir" || failed=1
    else
        print_info "已保留配置目录: $config_dir"
        print_info "已保留状态目录: $state_dir"
    fi

    if [[ "$failed" -ne 0 ]]; then
        print_error "Server Cat 卸载未完整完成，请根据上方错误手动检查"
        return 1
    fi

    print_success "Server Cat 已卸载"
    return 0
}
