#!/bin/bash
# 备份与恢复菜单

MENU_NAME="备份与恢复"
MENU_FUNC="backup_menu"

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"
source "$SCRIPT_DIR/../lib/backup_tools.sh"
source "$SCRIPT_DIR/restore_backup.sh"

function backup_menu() {
    init_backup_dirs

    while true; do
        clear
        echo -e "${BLUE}=====================================${NC}"
        echo -e "${BLUE}    💾 备份与恢复                 ${NC}"
        echo -e "${BLUE}=====================================${NC}"
        echo "1. 创建备份"
        echo "2. 查看备份列表"
        echo "3. 从备份恢复"
        echo "0. 返回主菜单"
        echo -e "${BLUE}-------------------------------------${NC}"
        read -p "请输入你的选择 [0-3]: " choice

        case $choice in
            1)
                source "$SCRIPT_DIR/create_backup.sh" && do_create_backup
                press_enter_to_continue
                ;;
            2)
                clear
                list_backups
                press_enter_to_continue
                ;;
            3)
                clear
                list_backups
                echo ""
                read -p "请输入备份文件名: " backup_name
                source "$SCRIPT_DIR/restore_backup.sh" && do_restore_backup "$backup_name"
                press_enter_to_continue
                ;;
            0) break ;;
            *) print_error "无效输入"; sleep 2 ;;
        esac
    done

    return 0
}

# 如果直接运行此脚本
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    backup_menu
fi
