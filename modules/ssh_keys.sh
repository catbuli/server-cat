#!/bin/bash

MENU_NAME="管理 SSH 公钥"
MENU_FUNC="manage_ssh_keys"
PRIORITY=25

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"

server_cat_ssh_keys_list_users() {
    getent passwd | awk -F: '
        ($3 == 0 || $3 >= 1000) &&
        $6 ~ /^\// &&
        $7 !~ /(nologin|false)$/ {
            print $1 "|" $3 "|" $4 "|" $6
        }
    '
}

server_cat_ssh_keys_select_user() {
    local record
    local username
    local uid
    local gid
    local home
    local choice
    local -a usernames
    local -a uids
    local -a gids
    local -a homes
    local -a labels

    while IFS='|' read -r username uid gid home; do
        [[ -n "$username" && -n "$home" ]] || continue
        usernames+=("$username")
        uids+=("$uid")
        gids+=("$gid")
        homes+=("$home")
        labels+=("$username ($home)")
    done < <(server_cat_ssh_keys_list_users)

    if [[ ${#usernames[@]} -eq 0 ]]; then
        print_error "没有找到可管理 SSH 公钥的登录用户"
        return 1
    fi

    choice=$(select_menu "选择用户" "$BLUE" "返回" "" "${labels[@]}")
    [[ "$choice" -eq 0 ]] && return 1
    if [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#usernames[@]} ]]; then
        print_error "无效用户选择"
        return 1
    fi

    SERVER_CAT_SSH_KEY_USER="${usernames[$((choice - 1))]}"
    SERVER_CAT_SSH_KEY_UID="${uids[$((choice - 1))]}"
    SERVER_CAT_SSH_KEY_GID="${gids[$((choice - 1))]}"
    SERVER_CAT_SSH_KEY_HOME="${homes[$((choice - 1))]}"
}

server_cat_ssh_keys_prepare_file() {
    local home="$1"
    local uid="$2"
    local gid="$3"
    local ssh_dir="$home/.ssh"
    local authorized_keys="$ssh_dir/authorized_keys"

    if [[ ! -d "$home" ]]; then
        print_error "用户 Home 目录不存在: $home"
        return 1
    fi
    if [[ -L "$ssh_dir" ]] || [[ -L "$authorized_keys" ]]; then
        print_error "拒绝操作符号链接形式的 .ssh 或 authorized_keys"
        return 1
    fi
    if [[ -e "$authorized_keys" && ! -f "$authorized_keys" ]]; then
        print_error "authorized_keys 不是常规文件: $authorized_keys"
        return 1
    fi

    install -d -m 0700 -o "$uid" -g "$gid" "$ssh_dir" || return 1
    if [[ ! -e "$authorized_keys" ]]; then
        install -m 0600 -o "$uid" -g "$gid" /dev/null "$authorized_keys" || return 1
    else
        chmod 0600 "$authorized_keys" || return 1
        chown "$uid:$gid" "$authorized_keys" || return 1
    fi

    SERVER_CAT_AUTHORIZED_KEYS="$authorized_keys"
}

server_cat_ssh_key_validate() {
    local public_key="$1"
    local key_file

    [[ -n "$public_key" ]] && [[ "$public_key" != *$'\n'* ]] || return 1
    command -v ssh-keygen > /dev/null 2>&1 || {
        print_error "缺少 ssh-keygen，无法校验公钥"
        return 1
    }

    key_file=$(mktemp) || return 1
    chmod 0600 "$key_file"
    printf '%s\n' "$public_key" > "$key_file"
    if ssh-keygen -lf "$key_file" > /dev/null 2>&1; then
        rm -f "$key_file"
        return 0
    fi

    rm -f "$key_file"
    return 1
}

server_cat_ssh_key_label() {
    local public_key="$1"
    local key_file
    local label

    key_file=$(mktemp) || return 1
    chmod 0600 "$key_file"
    printf '%s\n' "$public_key" > "$key_file"
    label=$(ssh-keygen -lf "$key_file" 2>/dev/null || true)
    rm -f "$key_file"
    label=$(printf '%s' "$label" | tr -cd '[:print:]')
    printf '%s\n' "${label:0:120}"
}

server_cat_ssh_keys_show() {
    local authorized_keys="$1"
    local line
    local label
    local count=0

    print_step "已授权 SSH 公钥"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" && "$line" != \#* ]] || continue
        count=$((count + 1))
        label=$(server_cat_ssh_key_label "$line")
        printf '  %d. %s\n' "$count" "${label:-无法识别的公钥条目}"
    done < "$authorized_keys"

    [[ "$count" -gt 0 ]] || print_info "当前没有已授权公钥"
}

server_cat_ssh_key_add() {
    local authorized_keys="$1"
    local public_key
    local label

    read -r -p "粘贴一行 SSH 公钥: " public_key
    if ! server_cat_ssh_key_validate "$public_key"; then
        print_error "SSH 公钥格式或内容无效"
        return 1
    fi
    if grep -Fxq -- "$public_key" "$authorized_keys"; then
        print_warning "该 SSH 公钥已经存在"
        return 0
    fi

    label=$(server_cat_ssh_key_label "$public_key")
    print_info "公钥指纹: ${label:-已通过校验}"
    confirm "确认添加该 SSH 公钥" "n" || return 0
    printf '%s\n' "$public_key" >> "$authorized_keys"
    print_success "SSH 公钥已添加"
}

server_cat_ssh_key_remove() {
    local authorized_keys="$1"
    local uid="$2"
    local gid="$3"
    local line
    local line_number=0
    local choice
    local target_line
    local edited_file
    local -a source_line_numbers
    local -a labels

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        [[ -n "$line" && "$line" != \#* ]] || continue
        source_line_numbers+=("$line_number")
        labels+=("$(server_cat_ssh_key_label "$line")")
    done < "$authorized_keys"

    if [[ ${#source_line_numbers[@]} -eq 0 ]]; then
        print_warning "当前没有可撤销的 SSH 公钥"
        return 0
    fi

    choice=$(select_menu \
        "撤销 SSH 公钥" \
        "$RED" \
        "取消" \
        "仅删除选中的一条公钥。" \
        "${labels[@]}")
    [[ "$choice" -eq 0 ]] && return 0
    if [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#source_line_numbers[@]} ]]; then
        print_error "无效公钥选择"
        return 1
    fi

    target_line="${source_line_numbers[$((choice - 1))]}"
    print_warning "即将撤销: ${labels[$((choice - 1))]}"
    confirm "确认撤销该 SSH 公钥" "n" || return 0

    edited_file=$(mktemp "$(dirname "$authorized_keys")/.authorized_keys.XXXXXX") || return 1
    if ! awk -v target="$target_line" 'NR != target { print }' "$authorized_keys" > "$edited_file"; then
        rm -f "$edited_file"
        return 1
    fi
    chmod 0600 "$edited_file"
    if [[ $EUID -eq 0 ]]; then
        chown "$uid:$gid" "$edited_file" || {
            rm -f "$edited_file"
            return 1
        }
    fi
    mv "$edited_file" "$authorized_keys"
    print_success "SSH 公钥已撤销"
}

server_cat_ssh_keys_user_menu() {
    local username="$1"
    local uid="$2"
    local gid="$3"
    local home="$4"
    local authorized_keys
    local choice

    server_cat_ssh_keys_prepare_file "$home" "$uid" "$gid" || return 1
    authorized_keys="$SERVER_CAT_AUTHORIZED_KEYS"

    while true; do
        choice=$(select_menu \
            "管理 $username 的 SSH 公钥" \
            "$BLUE" \
            "返回用户列表" \
            "只管理 authorized_keys，不读取或保存私钥。" \
            "查看公钥指纹" \
            "添加 SSH 公钥" \
            "撤销 SSH 公钥")

        case "$choice" in
            1) server_cat_ssh_keys_show "$authorized_keys" ;;
            2) server_cat_ssh_key_add "$authorized_keys" ;;
            3) server_cat_ssh_key_remove "$authorized_keys" "$uid" "$gid" ;;
            0) break ;;
            *) print_error "无效输入，请重试" ;;
        esac

        print_step "请按 [Enter] 键继续..."
        read -r
    done
}

function manage_ssh_keys() {
    while server_cat_ssh_keys_select_user; do
        server_cat_ssh_keys_user_menu \
            "$SERVER_CAT_SSH_KEY_USER" \
            "$SERVER_CAT_SSH_KEY_UID" \
            "$SERVER_CAT_SSH_KEY_GID" \
            "$SERVER_CAT_SSH_KEY_HOME"
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    manage_ssh_keys
fi
