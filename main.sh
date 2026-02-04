#!/bin/bash
# Server Toolkit - 主入口脚本

if [[ $EUID -ne 0 ]]; then
   echo "🚫 错误：此脚本必须使用 sudo 或以 root 身份运行。"
   exit 1
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
SOFTWARE_DIR="$SCRIPT_DIR/softwares"
MODULES_DIR="$SCRIPT_DIR/modules"
BACKUPS_DIR="$SCRIPT_DIR/backups"

source "$SCRIPT_DIR/lib/utils.sh"

function setup_permissions() {
    chmod +x "$SCRIPT_DIR"/modules/*.sh 2>/dev/null || true
    chmod +x "$SCRIPT_DIR"/softwares/*.sh 2>/dev/null || true
    chmod +x "$SCRIPT_DIR"/backups/*.sh 2>/dev/null || true
}

function press_enter_to_continue() {
    print_step "请按 [Enter] 键返回主菜单..."
    read
}

function get_menu_name() {
    local script="$1"
    local default_name="$2"
    # 提取 MENU_NAME 变量的值
    local name=$(grep "^MENU_NAME=" "$script" 2>/dev/null | head -1 | cut -d'"' -f2)
    if [[ -z "$name" ]]; then
        echo "$default_name"
    else
        echo "$name"
    fi
}

function get_menu_func() {
    local module="$1"
    local default_func="$2"
    # 提取 MENU_FUNC 变量的值
    local func=$(grep "^MENU_FUNC=" "$module" 2>/dev/null | head -1 | cut -d'"' -f2)
    if [[ -z "$func" ]]; then
        echo "$default_func"
    else
        echo "$func"
    fi
}

function get_rollback_func() {
    local script="$1"
    # 提取 ROLLBACK_FUNC 变量的值
    local func=$(grep "^ROLLBACK_FUNC=" "$script" 2>/dev/null | head -1 | cut -d'"' -f2)
    if [[ -n "$func" ]]; then
        echo "$func"
    fi
}

function get_priority() {
    local script="$1"
    # 提取 PRIORITY 变量的值，默认为 50
    local priority=$(grep "^PRIORITY=" "$script" 2>/dev/null | head -1 | cut -d'=' -f2)
    if [[ -z "$priority" ]]; then
        echo 50
    else
        echo "$priority"
    fi
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

function show_software_menu() {
    # 使用通用加载函数获取菜单项
    declare -a menu_funcs menu_names menu_priorities
    load_menu_items "$SOFTWARE_DIR" true

    local software_funcs=("${menu_funcs[@]}")
    local software_names=("${menu_names[@]}")

    while true; do
        clear
        echo -e "${BLUE}=====================================${NC}"
        echo -e "${BLUE}    📦 安装常用软件               ${NC}"
        echo -e "${BLUE}=====================================${NC}"

        if [ ${#software_funcs[@]} -eq 0 ]; then
            print_warning "在 'softwares' 目录中没有找到安装脚本 (.sh)"
        else
            echo "1. 全部安装"
            local i=2
            for name in "${software_names[@]}"; do
                echo "$i. $name"
                ((i++))
            done
        fi

        echo "0. 返回主菜单"
        echo -e "${BLUE}------------------------------------${NC}"
        read -p "请输入你的选择 [0-${#software_names[@]}]: " choice

        if [[ "$choice" -eq 0 ]]; then
            break
        elif [[ "$choice" -eq 1 ]]; then
            # 全部安装
            print_step "开始全部安装"
            local success_count=0
            local fail_count=0

            for i in "${!software_funcs[@]}"; do
                local func="${software_funcs[$i]}"
                local name="${software_names[$i]}"
                print_step "正在安装: $name"

                if $func; then
                    print_success "✓ $name 安装成功"
                    ((success_count++))
                else
                    print_error "✗ $name 安装失败"
                    ((fail_count++))
                fi
            done

            echo ""
            print_success "安装完成统计："
            echo "  • 成功: $success_count"
            echo "  • 失败: $fail_count"
            press_enter_to_continue
        elif [[ "$choice" -gt 1 && "$choice" -le $((${#software_names[@]} + 1)) ]]; then
            local idx=$((choice - 2))
            local func="${software_funcs[$idx]}"
            local name="${software_names[$idx]}"
            print_step "正在安装: $name"

            if $func; then
                print_success "✓ $name 安装成功"
            else
                print_error "✗ $name 安装失败"
            fi
            press_enter_to_continue
        else
            print_error "无效输入，请重试"
            sleep 2
        fi
    done
}

function show_settings_menu() {
    # 使用通用加载函数获取菜单项
    declare -a menu_funcs menu_names menu_priorities
    load_menu_items "$MODULES_DIR" true

    local module_funcs=("${menu_funcs[@]}")
    local module_names=("${menu_names[@]}")

    while true; do
        clear
        echo -e "${BLUE}=====================================${NC}"
        echo -e "${BLUE}    🔧 常用设置                   ${NC}"
        echo -e "${BLUE}=====================================${NC}"

        if [ ${#module_funcs[@]} -eq 0 ]; then
            print_warning "在 'modules' 目录中没有找到配置模块"
        else
            echo "1. 全部设置"
            local i=2
            for name in "${module_names[@]}"; do
                echo "$i. $name"
                ((i++))
            done
        fi

        echo "0. 返回主菜单"
        echo -e "${BLUE}------------------------------------${NC}"
        read -p "请输入你的选择 [0-${#module_names[@]}]: " choice

        if [[ "$choice" -eq 0 ]]; then
            break
        elif [[ "$choice" -eq 1 ]]; then
            # 全部设置
            print_step "开始全部设置"
            local success_count=0
            local fail_count=0

            for i in "${!module_funcs[@]}"; do
                local func="${module_funcs[$i]}"
                local name="${module_names[$i]}"
                print_step "正在执行: $name"

                if $func; then
                    print_success "✓ $name 执行成功"
                    ((success_count++))
                else
                    print_error "✗ $name 执行失败"
                    ((fail_count++))
                fi
            done

            echo ""
            print_success "设置完成统计："
            echo "  • 成功: $success_count"
            echo "  • 失败: $fail_count"
            press_enter_to_continue
        elif [[ "$choice" -gt 1 && "$choice" -le $((${#module_names[@]} + 1)) ]]; then
            local idx=$((choice - 2))
            local func="${module_funcs[$idx]}"
            local name="${module_names[$idx]}"
            print_step "正在执行: $name"

            # 备份菜单是子菜单，不显示执行结果
            if [[ "$func" == "backup_menu" ]]; then
                $func
            elif $func; then
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

function show_backup_menu() {
    # 调用备份系统的独立菜单
    source "$BACKUPS_DIR/backup_menu.sh"
    backup_menu
}

function show_rollback_menu() {
    # 第一次确认
    clear
    echo -e "${RED}=====================================${NC}"
    echo -e "${RED}    ⚠️  卸载                      ${NC}"
    echo -e "${RED}=====================================${NC}"
    print_warning "将会进行如下操作："
    print_warning "• 卸载所有已安装的软件"
    print_warning "• 恢复所有配置"
    print_warning "• 删除所有创建的目录和文件"
    echo ""
    print_prompt "请输入 'CONFIRM' 确认继续: "
    read -p "" first_confirm

    if [[ "$first_confirm" != "CONFIRM" ]]; then
        print_warning "已取消卸载"
        press_enter_to_continue
        return 0
    fi

    # 第二次确认
    echo ""
    print_warning "⚠️  最后确认！此操作不可逆！"
    print_prompt "请再次输入 'YES' 确认执行: "
    read -p "" second_confirm

    if [[ "$second_confirm" != "YES" ]]; then
        print_warning "已取消卸载"
        press_enter_to_continue
        return 0
    fi

    echo ""
    print_step "开始执行卸载..."

    # 收集所有 rollback 函数 (按优先级排序)
    declare -a rollback_funcs
    declare -a rollback_names
    declare -a temp_items

    # 从 modules 中获取
    mapfile -t modules < <(find "$MODULES_DIR" -maxdepth 1 -type f -name "*.sh" 2>/dev/null)
    for module in "${modules[@]}"; do
        source "$module"
        local func=$(get_rollback_func "$module")
        if [[ -n "$func" ]]; then
            local name=$(get_menu_name "$module" "$(basename "$module" .sh)")
            local priority=$(get_priority "$module")
            temp_items+=("$priority|$func|$name")
        fi
    done

    # 从 softwares 中获取
    mapfile -t softwares < <(find "$SOFTWARE_DIR" -maxdepth 1 -type f -name "*.sh" 2>/dev/null)
    for software in "${softwares[@]}"; do
        source "$software"
        local func=$(get_rollback_func "$software")
        if [[ -n "$func" ]]; then
            local name=$(get_menu_name "$software" "$(basename "$software" .sh)")
            local priority=$(get_priority "$software")
            temp_items+=("$priority|$func|$name")
        fi
    done

    # 按优先级排序
    IFS=$'\n' sorted_items=($(sort -t '|' -k1 -n <<<"${temp_items[*]}"))
    unset IFS

    for item in "${sorted_items[@]}"; do
        IFS='|' read -r priority func name <<< "$item"
        rollback_funcs+=("$func")
        rollback_names+=("$name")
    done

    # 执行所有 rollback 函数
    if [ ${#rollback_funcs[@]} -eq 0 ]; then
        print_warning "没有找到任何卸载函数"
    else
        print_info "准备执行 ${#rollback_funcs[@]} 个卸载功能..."
        echo ""

        # 设置批量执行标志，让 rollback 函数跳过内部确认
        export ROLLBACK_BATCH_MODE=1

        local success_count=0
        local fail_count=0

        for i in "${!rollback_funcs[@]}"; do
            local func="${rollback_funcs[$i]}"
            local name="${rollback_names[$i]}"
            print_step "[$((i+1))/${#rollback_funcs[@]}] 恢复: $name"

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
    fi

    press_enter_to_continue
}

function main_menu() {
    # 初始化目录和权限
    mkdir -p "$SOFTWARE_DIR" "$MODULES_DIR"
    setup_permissions

    while true; do
        clear
        echo -e "${GREEN}=====================================${NC}"
        echo -e "${GREEN}    Ubuntu 24 服务器自动化工具集   ${NC}"
        echo -e "${GREEN}=====================================${NC}"
        echo "1. 常用软件"
        echo "2. 常用设置"
        echo "3. 数据备份"
        echo "4. 卸载"
        echo "5. 退出"
        echo -e "${GREEN}------------------------------------${NC}"
        read -p "请输入你的选择 [1-5]: " main_choice

        case $main_choice in
            1) show_software_menu ;;
            2) show_settings_menu ;;
            3) show_backup_menu ;;
            4) show_rollback_menu ;;
            5) echo ""; print_success "👋 感谢使用，再见！"; exit 0 ;;
            *) print_error "无效输入，请重试"; sleep 2 ;;
        esac
    done
}

main_menu
