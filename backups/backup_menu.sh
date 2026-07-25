#!/bin/bash
# 备份与恢复菜单

MENU_NAME="备份与恢复"
MENU_FUNC="backup_menu"

BACKUPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$BACKUPS_DIR/../lib/utils.sh"
source "$BACKUPS_DIR/../lib/backup_tools.sh"
source "$BACKUPS_DIR/restore_backup.sh"

function backup_menu() {
    local choice

    init_backup_dirs

    while true; do
        choice=$(select_menu \
            "💾 备份与恢复" \
            "$BLUE" \
            "返回主菜单" \
            "" \
            "创建备份" "查看备份列表" "从备份恢复")

        case $choice in
            1)
                if source "$BACKUPS_DIR/create_backup.sh" && do_create_backup; then
                    :
                else
                    print_error "创建备份失败"
                fi
                press_enter_to_continue
                ;;
            2)
                clear_screen
                list_backups
                press_enter_to_continue
                ;;
            3)
                clear_screen
                list_backups
                echo ""
                read -p "请输入备份文件名: " backup_name
                if do_restore_backup "$backup_name"; then
                    :
                else
                    print_error "恢复备份失败"
                fi
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
