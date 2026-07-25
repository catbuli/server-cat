#!/bin/bash

MENU_NAME="清理系统空间"
MENU_FUNC="show_cleanup_menu"
PRIORITY=30

CLEANUP_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$CLEANUP_CONFIG_DIR/../lib/utils.sh"
source "$CLEANUP_CONFIG_DIR/../lib/cleanup.sh"

function show_cleanup_menu() {
    server_cat_cleanup_menu
}
