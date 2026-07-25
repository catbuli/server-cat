#!/bin/bash
# Server Toolkit - 主入口脚本

# 获取脚本真实目录（支持符号链接）
SCRIPT_SOURCE="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$( cd "$( dirname "$SCRIPT_SOURCE" )" &> /dev/null && pwd )"
SOFTWARE_DIR="$SCRIPT_DIR/softwares"
MODULES_DIR="$SCRIPT_DIR/modules"
BACKUPS_DIR="$SCRIPT_DIR/backups"
CONFIGS_DIR="$SCRIPT_DIR/configs"

source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/platform.sh"
source "$SCRIPT_DIR/lib/release.sh"
source "$SCRIPT_DIR/lib/agent.sh"

function show_command_help() {
    cat <<'EOF'
用法:
  sudo scat                       打开交互式菜单
  sudo scat update check          检查并验证 stable 发布版本
  sudo scat update apply          安装已验证的更新
  sudo scat update rollback 版本   回退已安装版本
  sudo scat agent check           立即执行一次监控检查
  sudo scat agent enable          启用每分钟监控
  sudo scat agent disable         停止并禁用每分钟监控
  sudo scat agent status          查看监控汇总状态
  sudo scat agent test-email      发送 SMTP 测试邮件
  sudo scat agent mute 30m        静默邮件通知 30 分钟
  sudo scat agent unmute          立即恢复邮件通知
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
                rollback)
                    [[ $# -eq 3 ]] || {
                        print_error "用法: scat update rollback <版本>"
                        return 1
                    }
                    server_cat_update_rollback "$3"
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
    chmod +x "$SCRIPT_DIR"/backups/*.sh 2>/dev/null || true
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
    local submenu_func="$7"

    declare -a menu_funcs menu_names menu_priorities
    load_menu_items "$dir" true

    local item_funcs=("${menu_funcs[@]}")
    local item_names=("${menu_names[@]}")

    while true; do
        clear
        echo -e "${BLUE}=====================================${NC}"
        echo -e "${BLUE}    $icon $title                   ${NC}"
        echo -e "${BLUE}=====================================${NC}"

        if [ ${#item_funcs[@]} -eq 0 ]; then
            print_warning "$empty_msg"
        else
            echo "1. $all_verb"
            local i=2
            for name in "${item_names[@]}"; do
                echo "$i. $name"
                ((i++))
            done
        fi

        echo "0. 返回主菜单"
        echo -e "${BLUE}-------------------------------------${NC}"
        read -p "请输入你的选择 [0-${#item_names[@]}]: " choice

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

            if [[ -n "$submenu_func" ]] && [[ "$func" == "$submenu_func" ]]; then
                call_menu_func "$func"
            elif call_menu_func "$func"; then
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
        "在 'modules' 目录中没有找到配置模块" \
        "backup_menu"
}

function show_configs_menu() {
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
        clear
        echo -e "${BLUE}=====================================${NC}"
        echo -e "${BLUE}    ⚙️  系统设置                 ${NC}"
        echo -e "${BLUE}=====================================${NC}"

        local i=1
        for name in "${item_names[@]}"; do
            echo "$i. $name"
            ((i++))
        done

        echo "0. 返回主菜单"
        echo -e "${BLUE}-------------------------------------${NC}"
        read -p "请输入你的选择 [0-${#item_names[@]}]: " choice

        if ! is_number "$choice"; then
            print_error "无效输入，请重试"
            sleep 2
        elif [[ "$choice" -eq 0 ]]; then
            break
        elif [[ "$choice" -ge 1 && "$choice" -le ${#item_names[@]} ]]; then
            local idx=$((choice - 1))
            local func="${item_funcs[$idx]}"
            clear
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

function show_backup_menu() {
    # 调用备份系统的独立菜单
    source "$BACKUPS_DIR/backup_menu.sh"
    backup_menu
}

function show_rollback_menu() {
    clear
    echo -e "${RED}=====================================${NC}"
    echo -e "${RED}    ⚠️  卸载                      ${NC}"
    echo -e "${RED}=====================================${NC}"
    print_warning "将会进行如下操作："
    print_warning "• 卸载所有已安装的软件"
    print_warning "• 恢复所有配置"
    print_warning "• 删除所有创建的目录和文件"
    echo ""

    confirm_strong "CONFIRM" "确认继续" || {
        print_warning "已取消卸载"
        press_enter_to_continue
        return 0
    }

    echo ""
    print_warning "⚠️  最后确认！此操作不可逆！"

    confirm_strong "YES" "最后确认" || {
        print_warning "已取消卸载"
        press_enter_to_continue
        return 0
    }

    echo ""
    print_step "开始执行卸载..."

    declare -a rollback_items
    collect_funcs "get_rollback_func" rollback_items

    if [ ${#rollback_items[@]} -eq 0 ]; then
        print_warning "没有找到任何卸载函数"
        press_enter_to_continue
        return 0
    fi

    print_info "准备执行 ${#rollback_items[@]} 个卸载功能..."
    echo ""

    export ROLLBACK_BATCH_MODE=1
    local success_count=0
    local fail_count=0

    for i in "${!rollback_items[@]}"; do
        IFS='|' read -r func name <<< "${rollback_items[$i]}"
        print_step "[$((i+1))/${#rollback_items[@]}] 恢复: $name"

        if call_menu_func "$func"; then
            print_success "✓ $name 卸载成功"
            ((success_count++))
        else
            print_error "✗ $name 卸载失败"
            ((fail_count++))
        fi
        echo ""
    done

    unset ROLLBACK_BATCH_MODE

    print_success "卸载完成统计："
    echo "  • 成功: $success_count"
    echo "  • 失败: $fail_count"

    press_enter_to_continue
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
            "常用软件" "常用设置" "数据备份" "系统设置" "卸载")

        case $choice in
            1) show_software_menu ;;
            2) show_settings_menu ;;
            3) show_backup_menu ;;
            4) show_configs_menu ;;
            5) show_rollback_menu ;;
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

if [[ $# -gt 0 ]]; then
    dispatch_command "$@"
    exit $?
fi

main_menu
