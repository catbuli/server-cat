#!/bin/bash
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_info() { echo -e "${BLUE}$1${NC}"; }
print_success() { echo -e "${GREEN}$1${NC}"; }
print_warning() { echo -e "${YELLOW}$1${NC}"; }
print_error() { echo -e "${RED}$1${NC}"; }
print_step() { echo -e "\n${YELLOW}$1${NC}"; }
print_prompt() { echo -e "${CYAN}$1${NC}"; }

check_command() {
    local cmd="$1"
    local name="${2:-$1}"
    if ! command -v "$cmd" &> /dev/null; then
        print_warning "⚠️  $name 未安装，跳过"
        return 1
    fi
    return 0
}

get_script_var() {
    local script="$1"
    local var_name="$2"
    local default_val="${3:-}"
    local val=$(grep "^${var_name}=" "$script" 2>/dev/null | head -1 | cut -d'"' -f2)
    echo "${val:-$default_val}"
}

get_backup_func() {
    get_script_var "$1" "BACKUP_FUNC"
}

get_priority() {
    local val=$(get_script_var "$1" "PRIORITY" "50")
    echo "${val:-50}"
}

get_menu_name() {
    get_script_var "$1" "MENU_NAME" "$2"
}

get_menu_func() {
    get_script_var "$1" "MENU_FUNC" "$2"
}

get_rollback_func() {
    get_script_var "$1" "ROLLBACK_FUNC"
}

confirm() {
    local prompt="${1:-确认?}"
    local default="${2:-n}"

    local prompt_suffix="[y/N]: "
    if [[ "$default" == "y" ]]; then
        prompt_suffix="[Y/n]: "
    fi

    print_prompt "$prompt $prompt_suffix"
    read -p "" response

    response=$(echo "$response" | tr '[:upper:]' '[:lower:]')

    if [[ -z "$response" ]]; then
        [[ "$default" == "y" ]]
        return $?
    fi

    [[ "$response" =~ ^y(es)?$ ]]
}

confirm_strong() {
    local required="$1"
    local prompt="${2:-确认}"

    print_prompt "$prompt (输入 '$required' 继续): "
    read -p "" response

    [[ "$response" == "$required" ]]
}

# 获取实际用户（处理 sudo 情况）
get_real_user() {
    if [[ -n "$SUDO_USER" ]]; then
        echo "$SUDO_USER"
    else
        echo "$USER"
    fi
}

# 获取实际用户主目录
get_real_home() {
    local real_user=$(get_real_user)
    getent passwd "$real_user" | cut -d: -f6
}

# 显示菜单
show_menu() {
    local title="$1"
    local color="$2"
    local zero_text="${3:-返回}"
    shift 3

    clear >&2
    echo -e "${color}=====================================${NC}" >&2
    echo -e "${color}    $title${NC}" >&2
    echo -e "${color}=====================================${NC}" >&2

    local i=1
    while [[ $# -gt 0 ]]; do
        echo "$i. $1" >&2
        shift
        ((i++))
    done

    echo "0. $zero_text" >&2
    echo -e "${color}-------------------------------------${NC}" >&2
    read -p "请输入你的选择 [0-$((i-1))]: " choice

    echo "$choice"
}
