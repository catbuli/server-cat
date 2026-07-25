#!/bin/bash

MENU_NAME="检查更新"
MENU_FUNC="check_update"
PRIORITY=10

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"
source "$SCRIPT_DIR/../lib/release.sh"

function check_update() {
    server_cat_update_check
}
