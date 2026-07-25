#!/bin/bash

MENU_NAME="检查 Server Cat 环境"
MENU_FUNC="doctor_server_cat"
PRIORITY=20

DOCTOR_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$DOCTOR_CONFIG_DIR/../lib/utils.sh"
source "$DOCTOR_CONFIG_DIR/../lib/release.sh"
source "$DOCTOR_CONFIG_DIR/../lib/doctor.sh"

function doctor_server_cat() {
    server_cat_doctor
}
