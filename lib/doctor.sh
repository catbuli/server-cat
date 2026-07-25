#!/bin/bash

# Server Cat 运行环境诊断。依赖调用方已加载 lib/utils.sh、lib/release.sh 与 lib/certbot.sh。

server_cat_doctor_agent_binary() {
    printf '%s\n' "${SERVER_CAT_AGENT_BINARY:-/opt/server-cat/current/server-cat-agent}"
}

server_cat_doctor_agent_config() {
    printf '%s\n' "${SERVER_CAT_AGENT_CONFIG:-/etc/server-cat/agent.toml}"
}

server_cat_doctor_file_mode() {
    local path="$1"

    stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null
}

server_cat_doctor_pass() {
    print_success "✓ $1"
}

server_cat_doctor_warn() {
    print_warning "! $1"
    SERVER_CAT_DOCTOR_WARNING_COUNT=$((SERVER_CAT_DOCTOR_WARNING_COUNT + 1))
}

server_cat_doctor_error() {
    print_error "✗ $1"
    SERVER_CAT_DOCTOR_ERROR_COUNT=$((SERVER_CAT_DOCTOR_ERROR_COUNT + 1))
}

server_cat_doctor_check_command() {
    local command_name="$1"

    if command -v "$command_name" > /dev/null 2>&1; then
        server_cat_doctor_pass "依赖可用: $command_name"
    else
        server_cat_doctor_error "缺少依赖: $command_name"
    fi
}

server_cat_doctor_check_timer() {
    local enabled
    local active

    if ! systemctl cat server-cat-agent.timer > /dev/null 2>&1; then
        server_cat_doctor_warn "未安装 Agent 定时器"
        return 0
    fi

    enabled=$(systemctl is-enabled server-cat-agent.timer 2>/dev/null || true)
    active=$(systemctl is-active server-cat-agent.timer 2>/dev/null || true)
    if [[ "$enabled" == "enabled" && "$active" == "active" ]]; then
        server_cat_doctor_pass "Agent 定时器已启用并运行中"
    else
        server_cat_doctor_warn "Agent 定时器当前为 $enabled ($active)，可执行 scat agent enable 启用"
    fi
}

server_cat_doctor_check_certbot_renewal() {
    if ! server_cat_certbot_is_installed; then
        print_info "○ 未安装 Certbot，跳过自动续期任务检查"
        return 0
    fi

    if server_cat_certbot_refresh_renew_timer_status; then
        server_cat_doctor_pass "Certbot 自动续期任务已启用并运行中"
    elif [[ "$SERVER_CAT_CERTBOT_TIMER_PRESENT" -eq 0 ]]; then
        server_cat_doctor_warn "已安装 Certbot，但未找到自动续期任务: $SERVER_CAT_CERTBOT_RENEW_TIMER"
    else
        server_cat_doctor_warn "Certbot 自动续期任务当前为 $SERVER_CAT_CERTBOT_TIMER_ENABLED ($SERVER_CAT_CERTBOT_TIMER_ACTIVE)"
    fi
}

server_cat_doctor() {
    local install_root
    local installed_version
    local agent_binary
    local agent_config
    local config_mode
    local command_name

    SERVER_CAT_DOCTOR_ERROR_COUNT=0
    SERVER_CAT_DOCTOR_WARNING_COUNT=0
    install_root=$(server_cat_install_root)
    agent_binary=$(server_cat_doctor_agent_binary)
    agent_config=$(server_cat_doctor_agent_config)

    print_step "检查 Server Cat 运行环境..."

    if installed_version=$(server_cat_installed_version); then
        server_cat_doctor_pass "已安装版本: $installed_version"
    else
        server_cat_doctor_error "未找到有效安装版本: $install_root/current/VERSION"
    fi

    if [[ -x "$agent_binary" ]]; then
        server_cat_doctor_pass "Agent 二进制可执行"
    else
        server_cat_doctor_error "未找到 Agent 二进制: $agent_binary"
    fi

    if [[ -r "$agent_config" ]]; then
        config_mode=$(server_cat_doctor_file_mode "$agent_config" || true)
        if [[ "$config_mode" == "600" ]]; then
            server_cat_doctor_pass "Agent 配置权限正确: 0600"
        else
            server_cat_doctor_error "Agent 配置权限应为 0600，当前为 ${config_mode:-未知}"
        fi

        if [[ -x "$agent_binary" ]] && "$agent_binary" validate-config --config "$agent_config"; then
            server_cat_doctor_pass "Agent 配置校验通过"
        else
            server_cat_doctor_error "Agent 配置校验失败"
        fi
    else
        server_cat_doctor_error "未找到 Agent 配置: $agent_config"
    fi

    for command_name in curl gpgv jq sha256sum tar zstd systemctl; do
        server_cat_doctor_check_command "$command_name"
    done

    if command -v systemctl > /dev/null 2>&1; then
        server_cat_doctor_check_timer
    fi

    server_cat_doctor_check_certbot_renewal

    if server_cat_update_check; then
        server_cat_doctor_pass "发布通道与签名验证通过"
    else
        server_cat_doctor_error "发布通道或签名验证失败"
    fi

    if [[ "$SERVER_CAT_DOCTOR_ERROR_COUNT" -gt 0 ]]; then
        print_error "诊断完成: $SERVER_CAT_DOCTOR_ERROR_COUNT 项错误，$SERVER_CAT_DOCTOR_WARNING_COUNT 项提醒"
        return 1
    fi

    if [[ "$SERVER_CAT_DOCTOR_WARNING_COUNT" -gt 0 ]]; then
        print_warning "诊断完成: 无错误，$SERVER_CAT_DOCTOR_WARNING_COUNT 项提醒"
    else
        print_success "诊断完成: 未发现问题"
    fi

    return 0
}
