#!/bin/bash

# systemd 服务管理。依赖调用方已加载 lib/utils.sh。

server_cat_service_name_valid() {
    [[ "$1" =~ ^[A-Za-z0-9_.@:-]+[.]service$ ]]
}

server_cat_service_require_systemd() {
    if ! command -v systemctl > /dev/null 2>&1; then
        print_error "当前系统缺少 systemctl，无法管理服务"
        return 1
    fi
    if ! systemctl list-units > /dev/null 2>&1; then
        print_error "无法连接 systemd"
        return 1
    fi
}

server_cat_service_list() {
    local mode="$1"
    local keyword="${2:-}"

    case "$mode" in
        failed)
            systemctl list-units --type=service --state=failed --no-legend --no-pager 2>/dev/null |
                awk '$1 ~ /[.]service$/ { print $1 }'
            ;;
        running)
            systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null |
                awk '$1 ~ /[.]service$/ { print $1 }'
            ;;
        search)
            systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null |
                awk -v keyword="$keyword" '$1 ~ /[.]service$/ && index(tolower($1), tolower(keyword)) { print $1 }'
            ;;
        *)
            return 1
            ;;
    esac
}

server_cat_service_select() {
    local mode="$1"
    local keyword="${2:-}"
    local service
    local state
    local choice
    local -a service_names
    local -a menu_items

    while IFS= read -r service; do
        server_cat_service_name_valid "$service" || continue
        service_names+=("$service")
    done < <(server_cat_service_list "$mode" "$keyword")

    if [[ ${#service_names[@]} -eq 0 ]]; then
        print_warning "没有找到符合条件的 systemd 服务"
        return 1
    fi

    for service in "${service_names[@]}"; do
        state=$(systemctl is-active "$service" 2>/dev/null || true)
        menu_items+=("[$state] $service")
    done

    choice=$(select_menu \
        "选择 systemd 服务" \
        "$BLUE" \
        "返回服务管理" \
        "每次只管理一个服务。" \
        "${menu_items[@]}")

    if [[ "$choice" -eq 0 ]]; then
        return 1
    fi
    if [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#service_names[@]} ]]; then
        print_error "无效服务选择"
        return 1
    fi

    SERVER_CAT_SELECTED_SERVICE="${service_names[$((choice - 1))]}"
}

server_cat_service_status() {
    local service="$1"

    server_cat_service_name_valid "$service" || {
        print_error "无效 systemd 服务名: $service"
        return 1
    }
    systemctl status "$service" --no-pager --full || true
}

server_cat_service_action() {
    local action="$1"
    local service="$2"
    local action_text

    server_cat_service_name_valid "$service" || {
        print_error "无效 systemd 服务名: $service"
        return 1
    }

    case "$action" in
        start) action_text="启动" ;;
        stop) action_text="停止" ;;
        restart) action_text="重启" ;;
        *)
            print_error "不支持的服务操作: $action"
            return 1
            ;;
    esac

    if ! confirm "确认${action_text} $service" "n"; then
        print_info "已取消${action_text} $service"
        return 0
    fi

    if systemctl "$action" "$service"; then
        print_success "$service ${action_text}成功"
    else
        print_error "$service ${action_text}失败"
        return 1
    fi
}

server_cat_service_actions_menu() {
    local service="$1"
    local choice

    while true; do
        choice=$(select_menu \
            "管理 $service" \
            "$BLUE" \
            "返回服务列表" \
            "所有变更操作均需确认。" \
            "查看状态" \
            "启动服务" \
            "停止服务" \
            "重启服务")

        case "$choice" in
            1) server_cat_service_status "$service" ;;
            2) server_cat_service_action start "$service" ;;
            3) server_cat_service_action stop "$service" ;;
            4) server_cat_service_action restart "$service" ;;
            0) break ;;
            *) print_error "无效输入，请重试" ;;
        esac

        print_step "请按 [Enter] 键继续..."
        read -r
    done
}

server_cat_service_manager_menu() {
    local choice
    local keyword

    server_cat_service_require_systemd || return 1

    while true; do
        choice=$(select_menu \
            "管理 systemd 服务" \
            "$BLUE" \
            "返回系统设置" \
            "先筛选服务，再执行单项操作。" \
            "查看失败服务" \
            "查看运行中服务" \
            "按名称查找服务")

        case "$choice" in
            1)
                if server_cat_service_select failed; then
                    server_cat_service_actions_menu "$SERVER_CAT_SELECTED_SERVICE"
                fi
                ;;
            2)
                if server_cat_service_select running; then
                    server_cat_service_actions_menu "$SERVER_CAT_SELECTED_SERVICE"
                fi
                ;;
            3)
                read -r -p "输入服务名关键词: " keyword
                if [[ -z "$keyword" ]] || [[ ! "$keyword" =~ ^[A-Za-z0-9_.@:-]+$ ]]; then
                    print_error "服务名关键词无效"
                elif server_cat_service_select search "$keyword"; then
                    server_cat_service_actions_menu "$SERVER_CAT_SELECTED_SERVICE"
                fi
                ;;
            0) break ;;
            *) print_error "无效输入，请重试" ;;
        esac
    done
}
