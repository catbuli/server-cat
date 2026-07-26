#!/bin/bash

MENU_NAME="管理 systemd 服务"
MENU_FUNC="manage_systemd_services"
PRIORITY=35

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"
source "$SCRIPT_DIR/../lib/services.sh"

function manage_systemd_services() {
    server_cat_service_manager_menu
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    manage_systemd_services
fi
