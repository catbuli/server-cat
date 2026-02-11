#!/bin/bash
# Server Toolkit - 主入口脚本

if [[ $EUID -ne 0 ]]; then
   echo "🚫 错误：此脚本必须使用 sudo 或以 root 身份运行。"
   exit 1
fi

# 获取脚本真实目录（支持符号链接）
SCRIPT_SOURCE="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$( cd "$( dirname "$SCRIPT_SOURCE" )" &> /dev/null && pwd )"
SOFTWARE_DIR="$SCRIPT_DIR/softwares"
MODULES_DIR="$SCRIPT_DIR/modules"
BACKUPS_DIR="$SCRIPT_DIR/backups"
CONFIGS_DIR="$SCRIPT_DIR/configs"

source "$SCRIPT_DIR/lib/utils.sh"

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

    mapfile -t scripts < <(find "$dir" -maxdepth 1 -type f -name "*.sh" 2>/dev/null)

    for script in "${scripts[@]}"; do
        source "$script"

        if [[ "$need_func" == "true" ]]; then
            local func=$(get_menu_func "$script" "")
            # 只添加有 MENU_FUNC 的脚本
            if [[ -z "$func" ]]; then
                continue
            fi
        fi

        local base_name=$(basename "$script" .sh)
        local name=$(get_menu_name "$script" "$base_name")
        local priority=$(get_priority "$script")

        if [[ "$need_func" == "true" ]]; then
            temp_items+=("$priority|$func|$name")
        else
            temp_items+=("$priority|$script|$name")
        fi
    done

    # 按优先级排序 (数字小的在前)
    IFS=$'\n' sorted_items=($(sort -t '|' -k1 -n <<<"${temp_items[*]}"))
    unset IFS

    # 填充返回数组
    for item in "${sorted_items[@]}"; do
        IFS='|' read -r priority item_identifier name <<< "$item"
        menu_priorities+=("$priority")
        if [[ "$need_func" == "true" ]]; then
            menu_funcs+=("$item_identifier")
        else
            menu_funcs+=("$item_identifier")
        fi
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
        mapfile -t scripts < <(find "$dir" -maxdepth 1 -type f -name "*.sh" 2>/dev/null)
        for script in "${scripts[@]}"; do
            source "$script"
            local func=$($func_extractor "$script")
            if [[ -n "$func" ]]; then
                local name=$(get_menu_name "$script" "$(basename "$script" .sh)")
                local priority=$(get_priority "$script")
                temp_items+=("$priority|$func|$name")
            fi
        done
    done

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

        if [[ "$choice" -eq 0 ]]; then
            break
        elif [[ "$choice" -eq 1 ]]; then
            print_step "开始$all_verb"
            local success_count=0
            local fail_count=0

            for i in "${!item_funcs[@]}"; do
                local func="${item_funcs[$i]}"
                local name="${item_names[$i]}"
                print_step "正在$action_verb: $name"

                if $func; then
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
                $func
            elif $func; then
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

        if [[ "$choice" -eq 0 ]]; then
            break
        elif [[ "$choice" -ge 1 && "$choice" -le ${#item_names[@]} ]]; then
            local idx=$((choice - 1))
            local func="${item_funcs[$idx]}"
            clear
            $func
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

        if $func; then
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
    mkdir -p "$SOFTWARE_DIR" "$MODULES_DIR" "$CONFIGS_DIR"
    setup_permissions

    while true; do
        local choice=$(show_menu \
            "Ubuntu 24 服务器自动化工具集" \
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

main_menu
