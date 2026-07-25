#!/bin/bash

# Linux 发行版与包管理器适配层。被 main.sh 和安装模块 source，不在顶层修改 shell 错误处理。

SERVER_CAT_OS_RELEASE_DEFAULT="/etc/os-release"

server_cat_platform_os_release_file() {
    printf '%s\n' "${SERVER_CAT_OS_RELEASE_FILE:-$SERVER_CAT_OS_RELEASE_DEFAULT}"
}

server_cat_platform_os_value() {
    local key="$1"
    local os_release_file
    local value

    os_release_file=$(server_cat_platform_os_release_file)
    [[ -r "$os_release_file" ]] || return 1

    value=$(sed -n "s/^${key}=//p" "$os_release_file" | head -n 1)
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"
    printf '%s\n' "$value"
}

server_cat_platform_id() {
    server_cat_platform_os_value "ID"
}

server_cat_platform_version() {
    server_cat_platform_os_value "VERSION_ID"
}

server_cat_platform_is_supported() {
    local os_id

    os_id=$(server_cat_platform_id) || return 1

    case "$os_id" in
        ubuntu|debian)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

server_cat_platform_description() {
    local os_id
    local os_version

    os_id=$(server_cat_platform_id 2>/dev/null || printf '%s' "unknown")
    os_version=$(server_cat_platform_version 2>/dev/null || printf '%s' "unknown")
    printf '%s %s\n' "$os_id" "$os_version"
}

server_cat_platform_support_message() {
    printf '%s\n' "当前支持使用 apt 和 systemd 的 Ubuntu、Debian 系统。"
}

server_cat_platform_require_supported() {
    if ! server_cat_platform_is_supported; then
        print_error "不支持的系统: $(server_cat_platform_description)"
        print_info "$(server_cat_platform_support_message)"
        return 1
    fi

    if ! command -v systemctl > /dev/null 2>&1; then
        print_error "当前系统未提供 systemctl，无法安装或管理 Server Cat Agent"
        return 1
    fi

    return 0
}

server_cat_platform_package_manager() {
    server_cat_platform_is_supported || return 1
    command -v apt-get > /dev/null 2>&1 || return 1
    printf '%s\n' "apt"
}

server_cat_platform_docker_distribution() {
    case "$(server_cat_platform_id)" in
        ubuntu|debian)
            server_cat_platform_id
            ;;
        *)
            return 1
            ;;
    esac
}
