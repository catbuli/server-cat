#!/bin/bash

# Agent 配置向导。依赖调用方已加载 lib/utils.sh 与 lib/agent.sh。

server_cat_agent_config_path() {
    printf '%s\n' "${SERVER_CAT_AGENT_CONFIG:-/etc/server-cat/agent.toml}"
}

server_cat_agent_config_binary() {
    printf '%s\n' "${SERVER_CAT_AGENT_BINARY:-/opt/server-cat/current/server-cat-agent}"
}

server_cat_agent_config_read() {
    local config_file="$1"
    local section="$2"
    local key="$3"

    awk -v target_section="$section" -v target_key="$key" '
        /^[[:space:]]*\[[^][]+\][[:space:]]*$/ {
            current = $0
            gsub(/^[[:space:]]*\[/, "", current)
            gsub(/\][[:space:]]*$/, "", current)
            in_target = (current == target_section)
            next
        }
        in_target {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            if (line ~ "^" target_key "[[:space:]]*=") {
                sub("^" target_key "[[:space:]]*=[[:space:]]*", "", line)
                print line
                exit
            }
        }
    ' "$config_file"
}

server_cat_agent_config_unquote() {
    local value="$1"

    if [[ "$value" == \"*\" ]] && [[ ${#value} -ge 2 ]]; then
        value="${value:1:${#value}-2}"
    fi
    value="${value//\\\"/\"}"
    value="${value//\\\\/\\}"
    printf '%s\n' "$value"
}

server_cat_agent_config_array_display() {
    local value="$1"

    value="${value#[}"
    value="${value%]}"
    value="${value//\"/}"
    value="${value//, /,}"
    printf '%s\n' "$value"
}

server_cat_agent_config_toml_string() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

server_cat_agent_config_toml_array() {
    local input="$1"
    local item
    local rendered=""
    local quoted
    local -a items

    [[ -n "$input" ]] || {
        printf '[]'
        return 0
    }

    IFS=',' read -r -a items <<< "$input"
    for item in "${items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ -n "$item" ]] || continue
        quoted=$(server_cat_agent_config_toml_string "$item")
        if [[ -n "$rendered" ]]; then
            rendered+=", "
        fi
        rendered+="$quoted"
    done

    printf '[%s]' "$rendered"
}

server_cat_agent_config_set() {
    local config_file="$1"
    local section="$2"
    local key="$3"
    local value="$4"
    local edited_file
    local value_file

    edited_file=$(mktemp "${config_file}.edit.XXXXXX") || return 1
    value_file=$(mktemp "${config_file}.value.XXXXXX") || {
        rm -f "$edited_file"
        return 1
    }
    chmod 0600 "$value_file"
    printf '%s\n' "$value" > "$value_file"
    if ! awk -v target_section="$section" -v target_key="$key" -v value_file="$value_file" '
        BEGIN {
            getline target_value < value_file
            close(value_file)
        }
        function print_value() {
            print target_key " = " target_value
            replaced = 1
        }
        /^[[:space:]]*\[[^][]+\][[:space:]]*$/ {
            if (in_target && !replaced) {
                print_value()
            }
            current = $0
            gsub(/^[[:space:]]*\[/, "", current)
            gsub(/\][[:space:]]*$/, "", current)
            in_target = (current == target_section)
            if (in_target) {
                found_section = 1
            }
            print
            next
        }
        in_target {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            if (line ~ "^" target_key "[[:space:]]*=") {
                print_value()
                next
            }
        }
        { print }
        END {
            if (in_target && !replaced) {
                print_value()
            } else if (!found_section) {
                print ""
                print "[" target_section "]"
                print_value()
            }
        }
    ' "$config_file" > "$edited_file"; then
        rm -f "$edited_file" "$value_file"
        return 1
    fi

    rm -f "$value_file"
    chmod 0600 "$edited_file"
    mv "$edited_file" "$config_file"
}

server_cat_agent_config_prepare() {
    local config_file
    local staged_file

    config_file=$(server_cat_agent_config_path)
    if [[ ! -f "$config_file" ]]; then
        print_error "未找到 Agent 配置: $config_file"
        return 1
    fi

    staged_file=$(mktemp "$(dirname "$config_file")/.agent.toml.XXXXXX") || {
        print_error "无法在配置目录创建临时文件"
        return 1
    }
    if ! cp "$config_file" "$staged_file"; then
        rm -f "$staged_file"
        print_error "无法读取现有 Agent 配置"
        return 1
    fi
    chmod 0600 "$staged_file"
    SERVER_CAT_AGENT_CONFIG_STAGED="$staged_file"
}

server_cat_agent_config_save() {
    local staged_file="$1"
    local config_file
    local agent_binary

    config_file=$(server_cat_agent_config_path)
    agent_binary=$(server_cat_agent_config_binary)
    if [[ ! -x "$agent_binary" ]]; then
        print_error "未找到可执行的 Agent: $agent_binary"
        rm -f "$staged_file"
        return 1
    fi

    print_step "校验新配置..."
    if ! "$agent_binary" validate-config --config "$staged_file"; then
        print_error "新配置校验失败，原配置未修改"
        rm -f "$staged_file"
        return 1
    fi

    if ! confirm "保存以上 Agent 配置" "y"; then
        print_info "已取消保存，原配置未修改"
        rm -f "$staged_file"
        return 0
    fi

    chmod 0600 "$staged_file"
    if [[ $EUID -eq 0 ]] && ! chown root:root "$staged_file"; then
        print_error "无法设置 Agent 配置所有者"
        rm -f "$staged_file"
        return 1
    fi
    if ! mv "$staged_file" "$config_file"; then
        print_error "无法保存 Agent 配置"
        rm -f "$staged_file"
        return 1
    fi

    print_success "Agent 配置已保存: $config_file"
}

server_cat_agent_config_prompt_value() {
    local label="$1"
    local current="$2"
    local input

    read -r -p "$label [$current]（留空保持不变）: " input
    SERVER_CAT_AGENT_CONFIG_VALUE="${input:-$current}"
}

server_cat_agent_config_prompt_integer() {
    local label="$1"
    local current="$2"
    local minimum="$3"
    local maximum="$4"
    local input
    local numeric_value

    while true; do
        read -r -p "$label [$current]（$minimum-$maximum，留空保持）: " input
        input="${input:-$current}"
        if is_number "$input" && [[ ${#input} -le 10 ]]; then
            numeric_value=$((10#$input))
            if [[ "$numeric_value" -ge "$minimum" && "$numeric_value" -le "$maximum" ]]; then
                SERVER_CAT_AGENT_CONFIG_VALUE="$numeric_value"
                return 0
            fi
        fi
        print_error "请输入 $minimum 到 $maximum 之间的整数"
    done
}

server_cat_agent_config_prompt_decimal() {
    local label="$1"
    local current="$2"
    local input

    while true; do
        read -r -p "$label [$current]（大于 0，留空保持）: " input
        input="${input:-$current}"
        if [[ "$input" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
            [[ ! "$input" =~ ^0+([.]0+)?$ ]]; then
            SERVER_CAT_AGENT_CONFIG_VALUE="$input"
            return 0
        fi
        print_error "请输入大于 0 的数字"
    done
}

server_cat_agent_config_prompt_boolean() {
    local label="$1"
    local current="$2"
    local input
    local current_label="否"

    [[ "$current" == "true" ]] && current_label="是"
    while true; do
        read -r -p "$label [$current_label]（y/n，留空保持）: " input
        input=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')
        case "$input" in
            "") SERVER_CAT_AGENT_CONFIG_VALUE="$current"; return 0 ;;
            y|yes) SERVER_CAT_AGENT_CONFIG_VALUE="true"; return 0 ;;
            n|no) SERVER_CAT_AGENT_CONFIG_VALUE="false"; return 0 ;;
            *) print_error "请输入 y 或 n" ;;
        esac
    done
}

server_cat_agent_config_prompt_optional() {
    local label="$1"
    local current="$2"
    local input

    read -r -p "$label [${current:-未配置}]（留空保持，输入 - 清空）: " input
    case "$input" in
        "") SERVER_CAT_AGENT_CONFIG_VALUE="$current" ;;
        -) SERVER_CAT_AGENT_CONFIG_VALUE="" ;;
        *) SERVER_CAT_AGENT_CONFIG_VALUE="$input" ;;
    esac
}

server_cat_agent_config_list_contains() {
    local needle="$1"
    local candidate
    shift

    for candidate in "$@"; do
        [[ "$candidate" == "$needle" ]] && return 0
    done

    return 1
}

server_cat_agent_config_select_docker_containers() {
    local current="$1"
    local docker_output
    local name
    local status
    local item
    local choice
    local save_index
    local select_all_index
    local clear_index
    local selected_value
    local -a current_items
    local -a container_names
    local -a container_statuses
    local -a menu_items
    local -a selected_names
    local -a updated_selected_names

    IFS=',' read -r -a current_items <<< "$current"
    for item in "${current_items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        if [[ -n "$item" ]] &&
            ! server_cat_agent_config_list_contains "$item" "${selected_names[@]}"; then
            selected_names+=("$item")
        fi
    done

    if ! command -v docker > /dev/null 2>&1; then
        print_warning "未安装 Docker，保持原有 Docker 巡检配置"
        SERVER_CAT_AGENT_CONFIG_VALUE="$current"
        return 0
    fi

    if ! docker_output=$(docker ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null); then
        print_warning "无法连接 Docker 服务，保持原有 Docker 巡检配置"
        SERVER_CAT_AGENT_CONFIG_VALUE="$current"
        return 0
    fi

    while IFS=$'\t' read -r name status; do
        [[ -n "$name" ]] || continue
        container_names+=("$name")
        container_statuses+=("${status:-状态未知}")
    done <<< "$docker_output"

    for item in "${current_items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        if [[ -n "$item" ]] &&
            ! server_cat_agent_config_list_contains "$item" "${container_names[@]}"; then
            container_names+=("$item")
            container_statuses+=("未发现")
        fi
    done

    if [[ ${#container_names[@]} -eq 0 ]]; then
        print_warning "Docker 中没有可选择的容器，保持原有 Docker 巡检配置"
        SERVER_CAT_AGENT_CONFIG_VALUE="$current"
        return 0
    fi

    while true; do
        menu_items=()
        for ((item = 0; item < ${#container_names[@]}; item++)); do
            name="${container_names[$item]}"
            if server_cat_agent_config_list_contains "$name" "${selected_names[@]}"; then
                menu_items+=("[x] $name (${container_statuses[$item]})")
            else
                menu_items+=("[ ] $name (${container_statuses[$item]})")
            fi
        done
        menu_items+=("全选容器" "清空选择" "保存选择")

        select_all_index=$((${#container_names[@]} + 1))
        clear_index=$((${#container_names[@]} + 2))
        save_index=$((${#container_names[@]} + 3))
        choice=$(select_menu \
            "选择 Docker 巡检容器" \
            "$BLUE" \
            "取消并保持原配置" \
            "选择容器后按 Enter 切换勾选，完成后选择保存。" \
            "${menu_items[@]}")

        if [[ "$choice" -eq 0 ]]; then
            SERVER_CAT_AGENT_CONFIG_VALUE="$current"
            print_info "已取消 Docker 容器选择，保持原配置"
            return 0
        fi

        if [[ "$choice" -eq "$select_all_index" ]]; then
            selected_names=("${container_names[@]}")
            continue
        fi

        if [[ "$choice" -eq "$clear_index" ]]; then
            selected_names=()
            continue
        fi

        if [[ "$choice" -eq "$save_index" ]]; then
            selected_value=""
            for name in "${container_names[@]}"; do
                server_cat_agent_config_list_contains "$name" "${selected_names[@]}" || continue
                if [[ -n "$selected_value" ]]; then
                    selected_value+=","
                fi
                selected_value+="$name"
            done
            SERVER_CAT_AGENT_CONFIG_VALUE="$selected_value"
            print_success "已选择 ${#selected_names[@]} 个 Docker 容器"
            return 0
        fi

        if [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#container_names[@]} ]]; then
            name="${container_names[$((choice - 1))]}"
            if server_cat_agent_config_list_contains "$name" "${selected_names[@]}"; then
                updated_selected_names=()
                for item in "${selected_names[@]}"; do
                    [[ "$item" != "$name" ]] && updated_selected_names+=("$item")
                done
                selected_names=("${updated_selected_names[@]}")
            else
                selected_names+=("$name")
            fi
        fi
    done
}

server_cat_agent_config_resources() {
    local staged_file
    local current

    server_cat_agent_config_prepare || return 1
    staged_file="$SERVER_CAT_AGENT_CONFIG_STAGED"

    print_step "配置巡检周期与资源阈值"
    print_info "磁盘和 inode 的警告阈值必须小于严重阈值。"

    current=$(server_cat_agent_config_read "$staged_file" schedule interval_seconds)
    server_cat_agent_config_prompt_integer "实际巡检间隔（秒）" "${current:-60}" 60 86400
    server_cat_agent_config_set "$staged_file" schedule interval_seconds "$SERVER_CAT_AGENT_CONFIG_VALUE" || return 1

    current=$(server_cat_agent_config_read "$staged_file" thresholds disk_warning_percent)
    server_cat_agent_config_prompt_integer "磁盘警告阈值（%）" "${current:-80}" 1 99
    server_cat_agent_config_set "$staged_file" thresholds disk_warning_percent "$SERVER_CAT_AGENT_CONFIG_VALUE" || return 1

    current=$(server_cat_agent_config_read "$staged_file" thresholds disk_critical_percent)
    server_cat_agent_config_prompt_integer "磁盘严重阈值（%）" "${current:-90}" 2 100
    server_cat_agent_config_set "$staged_file" thresholds disk_critical_percent "$SERVER_CAT_AGENT_CONFIG_VALUE" || return 1

    current=$(server_cat_agent_config_read "$staged_file" thresholds inode_warning_percent)
    server_cat_agent_config_prompt_integer "inode 警告阈值（%）" "${current:-80}" 1 99
    server_cat_agent_config_set "$staged_file" thresholds inode_warning_percent "$SERVER_CAT_AGENT_CONFIG_VALUE" || return 1

    current=$(server_cat_agent_config_read "$staged_file" thresholds inode_critical_percent)
    server_cat_agent_config_prompt_integer "inode 严重阈值（%）" "${current:-90}" 2 100
    server_cat_agent_config_set "$staged_file" thresholds inode_critical_percent "$SERVER_CAT_AGENT_CONFIG_VALUE" || return 1

    current=$(server_cat_agent_config_read "$staged_file" thresholds memory_warning_percent)
    server_cat_agent_config_prompt_integer "内存警告阈值（%）" "${current:-85}" 1 100
    server_cat_agent_config_set "$staged_file" thresholds memory_warning_percent "$SERVER_CAT_AGENT_CONFIG_VALUE" || return 1

    current=$(server_cat_agent_config_read "$staged_file" thresholds swap_warning_percent)
    server_cat_agent_config_prompt_integer "Swap 警告阈值（%）" "${current:-80}" 1 100
    server_cat_agent_config_set "$staged_file" thresholds swap_warning_percent "$SERVER_CAT_AGENT_CONFIG_VALUE" || return 1

    current=$(server_cat_agent_config_read "$staged_file" thresholds load_warning_per_cpu)
    server_cat_agent_config_prompt_decimal "每 CPU 负载警告阈值" "${current:-2.0}"
    server_cat_agent_config_set "$staged_file" thresholds load_warning_per_cpu "$SERVER_CAT_AGENT_CONFIG_VALUE" || return 1

    server_cat_agent_config_save "$staged_file"
}

server_cat_agent_config_checks() {
    local staged_file
    local current
    local rendered

    server_cat_agent_config_prepare || return 1
    staged_file="$SERVER_CAT_AGENT_CONFIG_STAGED"

    print_step "配置额外巡检目标"
    print_info "systemd、HTTP 和证书项目使用英文逗号分隔；Docker 容器通过菜单选择。"

    current=$(server_cat_agent_config_read "$staged_file" checks systemd_services)
    current=$(server_cat_agent_config_array_display "${current:-[]}")
    server_cat_agent_config_prompt_optional "systemd 服务" "$current"
    rendered=$(server_cat_agent_config_toml_array "$SERVER_CAT_AGENT_CONFIG_VALUE")
    server_cat_agent_config_set "$staged_file" checks systemd_services "$rendered" || return 1

    current=$(server_cat_agent_config_read "$staged_file" checks http_urls)
    current=$(server_cat_agent_config_array_display "${current:-[]}")
    server_cat_agent_config_prompt_optional "HTTP/HTTPS 地址" "$current"
    rendered=$(server_cat_agent_config_toml_array "$SERVER_CAT_AGENT_CONFIG_VALUE")
    server_cat_agent_config_set "$staged_file" checks http_urls "$rendered" || return 1

    current=$(server_cat_agent_config_read "$staged_file" checks http_timeout_seconds)
    server_cat_agent_config_prompt_integer "HTTP 超时（秒）" "${current:-10}" 1 300
    server_cat_agent_config_set "$staged_file" checks http_timeout_seconds "$SERVER_CAT_AGENT_CONFIG_VALUE" || return 1

    current=$(server_cat_agent_config_read "$staged_file" checks docker_containers)
    current=$(server_cat_agent_config_array_display "${current:-[]}")
    server_cat_agent_config_select_docker_containers "$current"
    rendered=$(server_cat_agent_config_toml_array "$SERVER_CAT_AGENT_CONFIG_VALUE")
    server_cat_agent_config_set "$staged_file" checks docker_containers "$rendered" || return 1

    current=$(server_cat_agent_config_read "$staged_file" checks check_reboot_required)
    server_cat_agent_config_prompt_boolean "检查服务器是否需要重启" "${current:-false}"
    server_cat_agent_config_set "$staged_file" checks check_reboot_required "$SERVER_CAT_AGENT_CONFIG_VALUE" || return 1

    current=$(server_cat_agent_config_read "$staged_file" checks certificate_paths)
    current=$(server_cat_agent_config_array_display "${current:-[]}")
    server_cat_agent_config_prompt_optional "TLS 证书绝对路径" "$current"
    rendered=$(server_cat_agent_config_toml_array "$SERVER_CAT_AGENT_CONFIG_VALUE")
    server_cat_agent_config_set "$staged_file" checks certificate_paths "$rendered" || return 1

    current=$(server_cat_agent_config_read "$staged_file" checks certificate_warning_days)
    server_cat_agent_config_prompt_integer "证书到期预警天数" "${current:-14}" 1 365
    server_cat_agent_config_set "$staged_file" checks certificate_warning_days "$SERVER_CAT_AGENT_CONFIG_VALUE" || return 1

    server_cat_agent_config_save "$staged_file"
}

server_cat_agent_config_email() {
    local staged_file
    local current
    local rendered
    local password

    server_cat_agent_config_prepare || return 1
    staged_file="$SERVER_CAT_AGENT_CONFIG_STAGED"

    print_step "配置邮件通知"
    current=$(server_cat_agent_config_read "$staged_file" email enabled)
    server_cat_agent_config_prompt_boolean "启用邮件通知" "${current:-false}"
    server_cat_agent_config_set "$staged_file" email enabled "$SERVER_CAT_AGENT_CONFIG_VALUE" || return 1

    if [[ "$SERVER_CAT_AGENT_CONFIG_VALUE" == "true" ]]; then
        current=$(server_cat_agent_config_read "$staged_file" email from)
        current=$(server_cat_agent_config_unquote "${current:-\"\"}")
        server_cat_agent_config_prompt_optional "发件人地址" "$current"
        rendered=$(server_cat_agent_config_toml_string "$SERVER_CAT_AGENT_CONFIG_VALUE")
        server_cat_agent_config_set "$staged_file" email from "$rendered" || return 1

        current=$(server_cat_agent_config_read "$staged_file" email recipients)
        current=$(server_cat_agent_config_array_display "${current:-[]}")
        server_cat_agent_config_prompt_optional "收件人地址" "$current"
        rendered=$(server_cat_agent_config_toml_array "$SERVER_CAT_AGENT_CONFIG_VALUE")
        server_cat_agent_config_set "$staged_file" email recipients "$rendered" || return 1

        current=$(server_cat_agent_config_read "$staged_file" email reminder_hours)
        server_cat_agent_config_prompt_integer "重复提醒间隔（小时）" "${current:-6}" 1 8760
        server_cat_agent_config_set "$staged_file" email reminder_hours "$SERVER_CAT_AGENT_CONFIG_VALUE" || return 1

        current=$(server_cat_agent_config_read "$staged_file" email smtp_host)
        current=$(server_cat_agent_config_unquote "${current:-\"\"}")
        server_cat_agent_config_prompt_optional "SMTP 主机" "$current"
        rendered=$(server_cat_agent_config_toml_string "$SERVER_CAT_AGENT_CONFIG_VALUE")
        server_cat_agent_config_set "$staged_file" email smtp_host "$rendered" || return 1

        current=$(server_cat_agent_config_read "$staged_file" email smtp_port)
        server_cat_agent_config_prompt_integer "SMTP 端口" "${current:-587}" 1 65535
        server_cat_agent_config_set "$staged_file" email smtp_port "$SERVER_CAT_AGENT_CONFIG_VALUE" || return 1

        current=$(server_cat_agent_config_read "$staged_file" email smtp_security)
        current=$(server_cat_agent_config_unquote "${current:-\"starttls\"}")
        while true; do
            server_cat_agent_config_prompt_value "SMTP 加密（starttls/tls/none）" "$current"
            case "$SERVER_CAT_AGENT_CONFIG_VALUE" in
                starttls|tls|none) break ;;
                *) print_error "SMTP 加密只能是 starttls、tls 或 none" ;;
            esac
        done
        rendered=$(server_cat_agent_config_toml_string "$SERVER_CAT_AGENT_CONFIG_VALUE")
        server_cat_agent_config_set "$staged_file" email smtp_security "$rendered" || return 1

        current=$(server_cat_agent_config_read "$staged_file" email smtp_username)
        current=$(server_cat_agent_config_unquote "${current:-\"\"}")
        server_cat_agent_config_prompt_optional "SMTP 用户名" "$current"
        rendered=$(server_cat_agent_config_toml_string "$SERVER_CAT_AGENT_CONFIG_VALUE")
        server_cat_agent_config_set "$staged_file" email smtp_username "$rendered" || return 1

        read -r -s -p "SMTP 密码（留空保持不变，输入 - 清空）: " password
        echo ""
        if [[ -n "$password" ]]; then
            [[ "$password" == "-" ]] && password=""
            rendered=$(server_cat_agent_config_toml_string "$password")
            server_cat_agent_config_set "$staged_file" email smtp_password "$rendered" || return 1
        fi
    fi

    server_cat_agent_config_save "$staged_file"
}

server_cat_agent_config_telegram() {
    local staged_file
    local current
    local rendered
    local bot_token

    server_cat_agent_config_prepare || return 1
    staged_file="$SERVER_CAT_AGENT_CONFIG_STAGED"

    print_step "配置 Telegram 通知"
    current=$(server_cat_agent_config_read "$staged_file" telegram enabled)
    server_cat_agent_config_prompt_boolean "启用 Telegram 通知" "${current:-false}"
    server_cat_agent_config_set "$staged_file" telegram enabled "$SERVER_CAT_AGENT_CONFIG_VALUE" || return 1

    if [[ "$SERVER_CAT_AGENT_CONFIG_VALUE" == "true" ]]; then
        read -r -s -p "Bot Token（留空保持不变，输入 - 清空）: " bot_token
        echo ""
        if [[ -n "$bot_token" ]]; then
            [[ "$bot_token" == "-" ]] && bot_token=""
            rendered=$(server_cat_agent_config_toml_string "$bot_token")
            server_cat_agent_config_set "$staged_file" telegram bot_token "$rendered" || return 1
        fi

        current=$(server_cat_agent_config_read "$staged_file" telegram chat_ids)
        current=$(server_cat_agent_config_array_display "${current:-[]}")
        server_cat_agent_config_prompt_optional "Chat ID（多个使用英文逗号分隔）" "$current"
        rendered=$(server_cat_agent_config_toml_array "$SERVER_CAT_AGENT_CONFIG_VALUE")
        server_cat_agent_config_set "$staged_file" telegram chat_ids "$rendered" || return 1

        current=$(server_cat_agent_config_read "$staged_file" telegram reminder_hours)
        server_cat_agent_config_prompt_integer "重复提醒间隔（小时）" "${current:-6}" 1 8760
        server_cat_agent_config_set "$staged_file" telegram reminder_hours "$SERVER_CAT_AGENT_CONFIG_VALUE" || return 1
    fi

    server_cat_agent_config_save "$staged_file"
}

server_cat_agent_config_notifications_menu() {
    local agent_binary
    local choice

    agent_binary=$(server_cat_agent_config_binary)
    while true; do
        choice=$(select_menu \
            "🔔 配置通知" \
            "$BLUE" \
            "返回上一级" \
            "" \
            "配置邮件通知" \
            "配置 Telegram 通知" \
            "发送测试邮件" \
            "发送 Telegram 测试通知")

        case "$choice" in
            1) server_cat_agent_config_email ;;
            2) server_cat_agent_config_telegram ;;
            3) "$agent_binary" test-email ;;
            4) "$agent_binary" test-telegram ;;
            0) break ;;
            *) print_error "无效输入，请重试" ;;
        esac

        print_step "请按 [Enter] 键继续..."
        read -r
    done

    return 0
}

server_cat_agent_config_validate() {
    local config_file
    local agent_binary

    config_file=$(server_cat_agent_config_path)
    agent_binary=$(server_cat_agent_config_binary)
    if [[ ! -x "$agent_binary" ]]; then
        print_error "未找到可执行的 Agent: $agent_binary"
        return 1
    fi

    "$agent_binary" validate-config --config "$config_file"
}

server_cat_agent_config_menu() {
    local agent_binary
    local choice

    agent_binary=$(server_cat_agent_config_binary)
    if [[ ! -x "$agent_binary" ]]; then
        print_error "未找到可执行的 Agent: $agent_binary"
        return 1
    fi

    while true; do
        choice=$(select_menu \
            "🐈 配置监控 Agent" \
            "$BLUE" \
            "返回上一级" \
            "" \
            "查看 Agent 状态" \
            "查看巡检日志" \
            "配置巡检周期与资源阈值" \
            "配置额外巡检目标" \
            "配置通知" \
            "校验当前配置" \
            "启用定时巡检" \
            "停止定时巡检")

        case "$choice" in
            1) "$agent_binary" status ;;
            2) server_cat_agent_logs ;;
            3) server_cat_agent_config_resources ;;
            4) server_cat_agent_config_checks ;;
            5) server_cat_agent_config_notifications_menu ;;
            6) server_cat_agent_config_validate ;;
            7)
                server_cat_agent_config_validate &&
                    systemctl enable --now server-cat-agent.timer &&
                    print_success "已启用 Server Cat 定时巡检"
                ;;
            8)
                systemctl disable --now server-cat-agent.timer &&
                    print_success "已停止 Server Cat 定时巡检"
                ;;
            0) break ;;
            *) print_error "无效输入，请重试" ;;
        esac

        print_step "请按 [Enter] 键继续..."
        read -r
    done

    return 0
}
