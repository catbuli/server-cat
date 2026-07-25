#!/bin/bash

# Agent CLI 分发层。依赖调用方已加载 lib/utils.sh。

server_cat_agent_binary() {
    printf '%s\n' "${SERVER_CAT_AGENT_BINARY:-/opt/server-cat/current/server-cat-agent}"
}

server_cat_agent_dispatch() {
    local subcommand="${1:-}"
    local agent_binary

    agent_binary=$(server_cat_agent_binary)

    case "$subcommand" in
        check)
            [[ $# -eq 1 ]] || {
                print_error "用法: scat agent check"
                return 1
            }
            "$agent_binary" check
            ;;
        enable)
            [[ $# -eq 1 ]] || {
                print_error "用法: scat agent enable"
                return 1
            }
            "$agent_binary" validate-config || return 1
            "$agent_binary" validate-smtp || return 1
            systemctl enable --now server-cat-agent.timer
            print_success "已启用 Server Cat 每分钟监控"
            ;;
        disable)
            [[ $# -eq 1 ]] || {
                print_error "用法: scat agent disable"
                return 1
            }
            systemctl disable --now server-cat-agent.timer
            print_success "已停止并禁用 Server Cat 每分钟监控"
            ;;
        status)
            [[ $# -eq 1 ]] || {
                print_error "用法: scat agent status"
                return 1
            }
            "$agent_binary" status
            ;;
        configure)
            [[ $# -eq 1 ]] || {
                print_error "用法: scat agent configure"
                return 1
            }
            server_cat_agent_config_menu
            ;;
        test-email)
            [[ $# -eq 1 ]] || {
                print_error "用法: scat agent test-email"
                return 1
            }
            "$agent_binary" test-email
            ;;
        mute)
            [[ $# -eq 2 ]] || {
                print_error "用法: scat agent mute <时长>，例如 30m、2h、1d"
                return 1
            }
            "$agent_binary" mute "$2"
            ;;
        unmute)
            [[ $# -eq 1 ]] || {
                print_error "用法: scat agent unmute"
                return 1
            }
            "$agent_binary" unmute
            ;;
        *)
            print_error "未知 Agent 命令: ${subcommand:-未提供}"
            return 1
            ;;
    esac
}
