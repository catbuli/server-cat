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

clear_screen() {
    if command clear 2>/dev/null; then
        return 0
    fi

    printf '\033[2J\033[H'
}

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
    local val

    val=$(sed -n "s/^${var_name}=//p" "$script" 2>/dev/null | head -n 1)
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"

    case "$val" in
        \"*\")
            val="${val#\"}"
            val="${val%\"}"
            ;;
        \'*\')
            val="${val#\'}"
            val="${val%\'}"
            ;;
        *)
            val="${val%%#*}"
            val="${val%"${val##*[![:space:]]}"}"
            ;;
    esac

    printf '%s\n' "${val:-$default_val}"
}

is_number() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

function_exists() {
    declare -F "$1" > /dev/null
}

call_menu_func() {
    local func="$1"

    if [[ -z "$func" ]] || ! function_exists "$func"; then
        print_error "功能不可用: ${func:-未声明}"
        return 1
    fi

    "$func"
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
    local real_user
    local real_home

    real_user=$(get_real_user)
    real_home=$(getent passwd "$real_user" 2>/dev/null | cut -d: -f6)

    if [[ -n "$real_home" ]]; then
        printf '%s\n' "$real_home"
    else
        printf '%s\n' "$HOME"
    fi
}

restart_ssh_service() {
    if systemctl restart sshd 2>/dev/null; then
        return 0
    fi

    systemctl restart ssh 2>/dev/null
}

server_cat_menu_render() {
    local title="$1"
    local color="$2"
    local zero_text="$3"
    local description="$4"
    local selected="$5"
    local interactive="$6"
    local index=0
    local label
    shift 6

    if [[ "$interactive" -eq 1 ]] || [[ -t 2 ]]; then
        clear_screen >&2
    fi
    echo -e "${color}=====================================${NC}" >&2
    echo -e "${color}    $title${NC}" >&2
    echo -e "${color}=====================================${NC}" >&2

    if [[ -n "$description" ]]; then
        printf '%s\n\n' "$description" >&2
    fi

    for label in "$@"; do
        if [[ "$selected" -eq "$index" ]]; then
            echo -e "${CYAN}> $((index + 1)). $label${NC}" >&2
        else
            printf '  %d. %s\n' "$((index + 1))" "$label" >&2
        fi
        index=$((index + 1))
    done

    if [[ "$selected" -eq "$index" ]]; then
        echo -e "${CYAN}> 0. $zero_text${NC}" >&2
    else
        printf '  0. %s\n' "$zero_text" >&2
    fi
    echo -e "${color}-------------------------------------${NC}" >&2

    if [[ "$interactive" -eq 1 ]]; then
        printf '↑/↓ 或 j/k 选择，Enter 确认，Backspace/Esc 返回；数字键可直接选择\n' >&2
    fi
}

select_menu() {
    local title="$1"
    local color="$2"
    local zero_text="${3:-返回}"
    local description="$4"
    local item_count
    local selected=0
    local choice
    local key
    local sequence
    local direction
    local escape_timeout="1"
    local interactive=0
    local -a items
    shift 4
    items=("$@")
    item_count=${#items[@]}

    if [[ "${SERVER_CAT_MENU_DEFAULT_ZERO:-0}" -eq 1 ]]; then
        selected="$item_count"
    fi

    if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
        escape_timeout="0.2"
    fi

    if [[ "${SERVER_CAT_MENU_FORCE_INTERACTIVE:-0}" -eq 1 ]] ||
        { [[ -t 0 ]] && [[ -t 2 ]]; }; then
        interactive=1
    fi

    if [[ "$interactive" -eq 0 ]]; then
        while true; do
            server_cat_menu_render "$title" "$color" "$zero_text" "$description" -1 0 "${items[@]}"
            if ! read -r -p "请输入你的选择 [0-$item_count]: " choice; then
                printf '0\n'
                return 0
            fi
            if is_number "$choice" && [[ "$choice" -ge 0 && "$choice" -le "$item_count" ]]; then
                printf '%s\n' "$choice"
                return 0
            fi
            print_error "无效输入，请重试" >&2
        done
    fi

    while true; do
        server_cat_menu_render "$title" "$color" "$zero_text" "$description" "$selected" 1 "${items[@]}"
        if ! IFS= read -r -s -n 1 key; then
            printf '0\n'
            return 0
        fi

        direction=""
        case "$key" in
            "")
                if [[ "$selected" -eq "$item_count" ]]; then
                    printf '0\n'
                else
                    printf '%s\n' "$((selected + 1))"
                fi
                return 0
                ;;
            j|J) direction="down" ;;
            k|K) direction="up" ;;
            q|Q|0|$'\b'|$'\177')
                printf '0\n'
                return 0
                ;;
            [1-9])
                if [[ "$key" -le "$item_count" ]]; then
                    printf '%s\n' "$key"
                    return 0
                fi
                ;;
            $'\033')
                sequence=""
                if ! IFS= read -r -s -n 1 -t "$escape_timeout" sequence; then
                    printf '0\n'
                    return 0
                fi
                if [[ "$sequence" == "[" || "$sequence" == "O" ]]; then
                    if ! IFS= read -r -s -n 1 -t "$escape_timeout" sequence; then
                        continue
                    fi
                    case "$sequence" in
                        A) direction="up" ;;
                        B) direction="down" ;;
                    esac
                fi
                ;;
        esac

        case "$direction" in
            up)
                if [[ "$selected" -eq 0 ]]; then
                    selected="$item_count"
                else
                    selected=$((selected - 1))
                fi
                ;;
            down)
                if [[ "$selected" -eq "$item_count" ]]; then
                    selected=0
                else
                    selected=$((selected + 1))
                fi
                ;;
        esac
    done
}

# 兼容现有主菜单调用方式。
show_menu() {
    local title="$1"
    local color="$2"
    local zero_text="${3:-返回}"
    shift 3

    select_menu "$title" "$color" "$zero_text" "" "$@"
}
