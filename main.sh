#!/bin/bash
# Server Toolkit - 主入口脚本

# 获取脚本真实目录（支持符号链接）
SCRIPT_SOURCE="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$( cd "$( dirname "$SCRIPT_SOURCE" )" &> /dev/null && pwd )"
SOFTWARE_DIR="$SCRIPT_DIR/softwares"
MODULES_DIR="$SCRIPT_DIR/modules"
CONFIGS_DIR="$SCRIPT_DIR/configs"

source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/platform.sh"
source "$SCRIPT_DIR/lib/release.sh"
source "$SCRIPT_DIR/lib/certbot.sh"
source "$SCRIPT_DIR/lib/doctor.sh"
source "$SCRIPT_DIR/lib/agent.sh"
source "$SCRIPT_DIR/lib/agent_config.sh"
source "$SCRIPT_DIR/lib/uninstall.sh"

function show_command_help() {
    cat <<'EOF'
用法:
  sudo scat                       打开交互式菜单
  sudo scat update check          检查并验证 stable 发布版本
  sudo scat update apply          安装已验证的更新
  sudo scat doctor                检查 Server Cat 运行环境
  sudo scat agent check           立即执行一次监控检查
  sudo scat agent enable          启用每分钟监控
  sudo scat agent disable         停止并禁用每分钟监控
  sudo scat agent status          查看监控汇总状态
  sudo scat agent logs            查看最近 100 行巡检日志
  sudo scat agent logs --follow   持续查看巡检日志
  sudo scat agent configure       打开 Agent 配置向导
  sudo scat agent test-email      发送 SMTP 测试邮件
  sudo scat agent test-telegram   发送 Telegram 测试通知
  sudo scat agent mute 30m        静默外部通知 30 分钟
  sudo scat agent unmute          立即恢复外部通知
EOF
}

function require_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此命令必须使用 sudo 或以 root 身份运行"
        return 1
    fi

    return 0
}

function dispatch_command() {
    local command="$1"
    local subcommand="${2:-}"

    case "$command" in
        update)
            case "$subcommand" in
                check)
                    [[ $# -eq 2 ]] || {
                        print_error "用法: scat update check"
                        return 1
                    }
                    server_cat_update_check
                    ;;
                apply)
                    [[ $# -eq 2 ]] || {
                        print_error "用法: scat update apply"
                        return 1
                    }
                    server_cat_update_apply
                    ;;
                *)
                    print_error "未知更新命令: ${subcommand:-未提供}"
                    return 1
                    ;;
            esac
            ;;
        agent)
            server_cat_agent_dispatch "${@:2}"
            ;;
        doctor)
            [[ $# -eq 1 ]] || {
                print_error "用法: scat doctor"
                return 1
            }
            server_cat_doctor
            ;;
        help|--help|-h)
            show_command_help
            ;;
        *)
            print_error "未知命令: $command"
            show_command_help
            return 1
            ;;
    esac
}

function setup_permissions() {
    chmod +x "$SCRIPT_DIR"/modules/*.sh 2>/dev/null || true
    chmod +x "$SCRIPT_DIR"/softwares/*.sh 2>/dev/null || true
    chmod +x "$SCRIPT_DIR"/configs/*.sh 2>/dev/null || true
}

function press_enter_to_continue() {
    print_step "请按 [Enter] 键返回主菜单..."
    read
}

# 通用菜单项加载函数
# 参数: $1=目录路径, $2=是否需要 MENU_FUNC (true/false)
# 返回: 全局数组 menu_funcs, menu_names, menu_priorities
function load_menu_items() {
    local dir="$1"
    local need_func="$2"

    # 清空数组
    menu_funcs=()
    menu_names=()
    menu_priorities=()

    # 临时存储: priority|func|name
    declare -a temp_items

    mapfile -t scripts < <(find "$dir" -maxdepth 1 -type f -name "*.sh" -print 2>/dev/null | sort)

    for script in "${scripts[@]}"; do
        if ! source "$script"; then
            print_warning "跳过无法加载的脚本: $(basename "$script")"
            continue
        fi

        if [[ "$need_func" == "true" ]]; then
            local func
            func=$(get_menu_func "$script" "")
            if [[ -z "$func" ]] || ! function_exists "$func"; then
                print_warning "跳过无效菜单项: $(basename "$script")"
                continue
            fi
        fi

        local base_name
        local name
        local priority
        base_name=$(basename "$script" .sh)
        name=$(get_menu_name "$script" "$base_name")
        priority=$(get_priority "$script")

        if ! is_number "$priority"; then
            print_warning "跳过优先级无效的脚本: $(basename "$script")"
            continue
        fi

        if [[ "$need_func" == "true" ]]; then
            temp_items+=("$priority|$func|$name")
        else
            temp_items+=("$priority|$script|$name")
        fi
    done

    if [[ ${#temp_items[@]} -eq 0 ]]; then
        return 0
    fi

    # 按优先级排序 (数字小的在前)
    IFS=$'\n' sorted_items=($(sort -t '|' -k1 -n <<<"${temp_items[*]}"))
    unset IFS

    # 填充返回数组
    for item in "${sorted_items[@]}"; do
        IFS='|' read -r priority item_identifier name <<< "$item"
        menu_priorities+=("$priority")
        menu_funcs+=("$item_identifier")
        menu_names+=("$name")
    done
}

# 收集指定类型的函数（如 rollback_func）
# 参数: $1=函数类型(get_rollback_func), $2=输出数组名
function collect_funcs() {
    local func_extractor="$1"
    local -n output_array="$2"
    declare -a temp_items

    for dir in "$MODULES_DIR" "$SOFTWARE_DIR"; do
        mapfile -t scripts < <(find "$dir" -maxdepth 1 -type f -name "*.sh" -print 2>/dev/null | sort)
        for script in "${scripts[@]}"; do
            if ! source "$script"; then
                print_warning "跳过无法加载的脚本: $(basename "$script")"
                continue
            fi

            local func
            local name
            local priority
            func=$($func_extractor "$script")
            if [[ -z "$func" ]] || ! function_exists "$func"; then
                continue
            fi

            name=$(get_menu_name "$script" "$(basename "$script" .sh)")
            priority=$(get_priority "$script")
            if is_number "$priority"; then
                temp_items+=("$priority|$func|$name")
            fi
        done
    done

    if [[ ${#temp_items[@]} -eq 0 ]]; then
        return 0
    fi

    IFS=$'\n' sorted_items=($(sort -t '|' -k1 -n <<<"${temp_items[*]}"))
    unset IFS

    for item in "${sorted_items[@]}"; do
        IFS='|' read -r priority func name <<< "$item"
        output_array+=("$func|$name")
    done
}

function show_generic_menu() {
    local title="$1"
    local icon="$2"
    local dir="$3"
    local action_verb="$4"
    local all_verb="$5"
    local empty_msg="$6"
    local choice

    declare -a menu_funcs menu_names menu_priorities
    load_menu_items "$dir" true

    local item_funcs=("${menu_funcs[@]}")
    local item_names=("${menu_names[@]}")
    local description=""
    local -a options

    if [[ ${#item_funcs[@]} -eq 0 ]]; then
        description="$empty_msg"
        options=()
    else
        options=("$all_verb" "${item_names[@]}")
    fi

    while true; do
        choice=$(select_menu "$icon $title" "$BLUE" "返回主菜单" "$description" "${options[@]}")

        if ! is_number "$choice"; then
            print_error "无效输入，请重试"
            sleep 2
        elif [[ "$choice" -eq 0 ]]; then
            break
        elif [[ "$choice" -eq 1 ]]; then
            print_step "开始$all_verb"
            local success_count=0
            local fail_count=0

            for i in "${!item_funcs[@]}"; do
                local func="${item_funcs[$i]}"
                local name="${item_names[$i]}"
                print_step "正在$action_verb: $name"

                if call_menu_func "$func"; then
                    print_success "✓ $name ${action_verb}成功"
                    ((success_count++))
                else
                    print_error "✗ $name ${action_verb}失败"
                    ((fail_count++))
                fi
            done

            echo ""
            print_success "${action_verb}完成统计："
            echo "  • 成功: $success_count"
            echo "  • 失败: $fail_count"
            press_enter_to_continue
        elif [[ "$choice" -gt 1 && "$choice" -le $((${#item_names[@]} + 1)) ]]; then
            local idx=$((choice - 2))
            local func="${item_funcs[$idx]}"
            local name="${item_names[$idx]}"
            print_step "正在$action_verb: $name"

            if call_menu_func "$func"; then
                print_success "✓ $name ${action_verb}成功"
            else
                print_error "✗ $name ${action_verb}失败"
            fi
            press_enter_to_continue
        else
            print_error "无效输入，请重试"
            sleep 2
        fi
    done
}

function show_software_menu() {
    show_generic_menu \
        "安装常用软件" \
        "📦" \
        "$SOFTWARE_DIR" \
        "安装" \
        "全部安装" \
        "在 'softwares' 目录中没有找到安装脚本 (.sh)"
}

function show_settings_menu() {
    show_generic_menu \
        "常用设置" \
        "🔧" \
        "$MODULES_DIR" \
        "执行" \
        "全部设置" \
        "在 'modules' 目录中没有找到配置模块"
}

function show_configs_menu() {
    local choice

    declare -a menu_funcs menu_names menu_priorities
    load_menu_items "$CONFIGS_DIR" true

    local item_funcs=("${menu_funcs[@]}")
    local item_names=("${menu_names[@]}")

    if [ ${#item_funcs[@]} -eq 0 ]; then
        print_warning "没有找到系统设置脚本"
        press_enter_to_continue
        return 0
    fi

    while true; do
        choice=$(select_menu "⚙️  系统设置" "$BLUE" "返回主菜单" "" "${item_names[@]}")

        if ! is_number "$choice"; then
            print_error "无效输入，请重试"
            sleep 2
        elif [[ "$choice" -eq 0 ]]; then
            break
        elif [[ "$choice" -ge 1 && "$choice" -le ${#item_names[@]} ]]; then
            local idx=$((choice - 1))
            local func="${item_funcs[$idx]}"
            clear_screen
            if ! call_menu_func "$func"; then
                print_error "功能执行失败"
            fi
            press_enter_to_continue
        else
            print_error "无效输入，请重试"
            sleep 2
        fi
    done
}

function show_server_cat_uninstall() {
    clear_screen
    echo -e "${RED}=====================================${NC}"
    echo -e "${RED}    ⚠️  卸载 Server Cat           ${NC}"
    echo -e "${RED}=====================================${NC}"
    print_warning "将停止 Agent 并删除以下 Server Cat 自身组件："
    print_warning "• /opt/server-cat 程序目录"
    print_warning "• scat 与 server-cat 命令"
    print_warning "• Agent systemd 服务、定时器和 Bash 补全"
    print_info "不会卸载 Docker、Nginx、Certbot 或安装依赖"
    print_info "默认保留 /etc/server-cat 和 /var/lib/server-cat"
    echo ""

    confirm_strong "UNINSTALL" "确认卸载 Server Cat" || {
        print_warning "已取消卸载"
        press_enter_to_continue
        return 0
    }

    local remove_data=0
    if confirm "是否同时删除 Agent 配置、通知凭据和告警状态" "n"; then
        print_warning "删除后无法通过重新安装恢复这些配置和状态"
        if confirm_strong "DELETE" "确认删除 /etc/server-cat 和 /var/lib/server-cat"; then
            remove_data=1
        else
            print_warning "未完成数据删除确认，将保留配置和状态"
        fi
    fi

    if ! server_cat_uninstall_execute "$remove_data"; then
        press_enter_to_continue
        return 1
    fi

    print_info "卸载程序即将退出；如需重新使用，请重新运行官方安装命令"
    exit 0
}

function show_component_rollback_menu() {
    declare -a rollback_items
    collect_funcs "get_rollback_func" rollback_items
    local -a rollback_funcs rollback_names
    local item
    local func
    local name
    local choice

    if [ ${#rollback_items[@]} -eq 0 ]; then
        print_warning "没有找到可用的单项恢复或卸载功能"
        press_enter_to_continue
        return 0
    fi

    for item in "${rollback_items[@]}"; do
        IFS='|' read -r func name <<< "$item"
        rollback_funcs+=("$func")
        rollback_names+=("$name")
    done

    while true; do
        choice=$(select_menu \
            "↩️  单项恢复或卸载" \
            "$RED" \
            "返回卸载与恢复" \
            "仅执行选中的功能，不会批量修改其他软件或系统配置。" \
            "${rollback_names[@]}")

        if ! is_number "$choice"; then
            print_error "无效输入，请重试"
            sleep 2
        elif [[ "$choice" -eq 0 ]]; then
            break
        elif [[ "$choice" -ge 1 && "$choice" -le ${#rollback_names[@]} ]]; then
            local idx=$((choice - 1))
            func="${rollback_funcs[$idx]}"
            name="${rollback_names[$idx]}"
            clear_screen
            print_warning "即将只执行：$name"
            print_warning "该操作可能卸载软件或恢复系统配置，请确认你了解其影响"

            if ! confirm "确认继续" "n"; then
                print_warning "已取消操作"
            elif call_menu_func "$func"; then
                print_success "✓ $name 执行成功"
            else
                print_error "✗ $name 执行失败"
            fi
            press_enter_to_continue
        else
            print_error "无效输入，请重试"
            sleep 2
        fi
    done
}

function show_uninstall_menu() {
    local choice

    while true; do
        choice=$(select_menu \
            "⚠️  卸载与恢复" \
            "$RED" \
            "返回主菜单" \
            "Server Cat 自卸载与系统组件恢复互相独立。" \
            "卸载 Server Cat" \
            "单项恢复或卸载")

        case "$choice" in
            1) show_server_cat_uninstall ;;
            2) show_component_rollback_menu ;;
            0) break ;;
            *) print_error "无效输入，请重试"; sleep 2 ;;
        esac
    done
}

function main_menu() {
    server_cat_platform_require_supported || return 1
    mkdir -p "$SOFTWARE_DIR" "$MODULES_DIR" "$CONFIGS_DIR"
    setup_permissions

    while true; do
        local choice=$(show_menu \
            "Ubuntu / Debian 服务器管理工具" \
            "${GREEN}" \
            "退出" \
            "常用软件" "常用设置" "系统设置" "卸载与恢复")

        case $choice in
            1) show_software_menu ;;
            2) show_settings_menu ;;
            3) show_configs_menu ;;
            4) show_uninstall_menu ;;
            0) echo ""; print_success "👋 感谢使用，再见！"; exit 0 ;;
            *) print_error "无效输入，请重试"; sleep 2 ;;
        esac
    done
}

if [[ $# -gt 0 ]] && [[ "$1" =~ ^(help|--help|-h)$ ]]; then
    show_command_help
    exit 0
fi

require_root || exit 1

server_cat_release_migrate_legacy_layout || exit 1
if [[ "$SERVER_CAT_LEGACY_LAYOUT_MIGRATED" -eq 1 ]]; then
    exec "$(server_cat_install_root)/current/main.sh" "$@"
fi

if [[ $# -gt 0 ]]; then
    dispatch_command "$@"
    exit $?
fi

main_menu
