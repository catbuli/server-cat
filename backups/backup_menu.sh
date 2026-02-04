#!/bin/bash
# 备份与恢复菜单

MENU_NAME="备份与恢复"
MENU_FUNC="backup_menu"

set -eo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "$SCRIPT_DIR/../lib/utils.sh"
source "$SCRIPT_DIR/backup_common.sh"
source "$SCRIPT_DIR/backup_items.sh"
source "$SCRIPT_DIR/remote_backup.sh"

function backup_menu() {
    init_backup_dirs

    while true; do
        clear
        echo -e "${BLUE}=====================================${NC}"
        echo -e "${BLUE}    💾 备份与恢复                 ${NC}"
        echo -e "${BLUE}=====================================${NC}"
        echo "1. 创建完整备份"
        echo "2. 创建每日备份"
        echo "3. 创建每周备份"
        echo "4. 查看备份列表"
        echo "5. 从备份恢复"
        echo "6. 配置远程备份"
        echo "7. 复制备份到远程"
        echo "8. 同步备份到远程"
        echo "9. 测试远程连接"
        echo "0. 返回主菜单"
        echo -e "${BLUE}-------------------------------------${NC}"
        read -p "请输入你的选择 [0-9]: " choice

        case $choice in
            1) source "$SCRIPT_DIR/create_backup.sh" && do_create_backup "full"; press_enter_to_continue ;;
            2) source "$SCRIPT_DIR/create_backup.sh" && do_create_backup "daily"; press_enter_to_continue ;;
            3) source "$SCRIPT_DIR/create_backup.sh" && do_create_backup "weekly"; press_enter_to_continue ;;
            4)
                clear
                list_backups_by_type
                press_enter_to_continue
                ;;
            5)
                clear
                list_backups_by_type
                echo ""
                read -p "请输入备份文件名: " backup_name
                source "$SCRIPT_DIR/restore_backup.sh" && do_restore_backup "$backup_name"
                press_enter_to_continue
                ;;
            6)
                configure_remote
                press_enter_to_continue
                ;;
            7)
                clear
                list_backups_by_type
                echo ""
                read -p "请输入要复制的备份文件名: " backup_name
                for type in full daily weekly monthly; do
                    if [ -f "$BACKUP_ROOT/$type/${backup_name}.tar.gz" ]; then
                        copy_to_remote "$BACKUP_ROOT/$type/${backup_name}.tar.gz"
                        break
                    fi
                done
                press_enter_to_continue
                ;;
            8)
                read -p "同步类型? [full/daily/weekly/monthal]: " sync_type
                sync_to_remote "${sync_type:-full}"
                press_enter_to_continue
                ;;
            9)
                test_remote_connection
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
