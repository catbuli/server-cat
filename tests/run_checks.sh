#!/bin/bash
# 不执行服务器操作，仅验证脚本结构与可安全加载性。

set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_COUNT=0
FAIL_COUNT=0

pass() {
    CHECK_COUNT=$((CHECK_COUNT + 1))
    printf 'PASS %s\n' "$1"
}

fail() {
    CHECK_COUNT=$((CHECK_COUNT + 1))
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL %s\n' "$1" >&2
}

assert_contains() {
    local file="$1"
    local pattern="$2"
    local description="$3"

    if rg -q -- "$pattern" "$PROJECT_ROOT/$file"; then
        pass "$description"
    else
        fail "$description"
    fi
}

assert_not_contains() {
    local file="$1"
    local pattern="$2"
    local description="$3"

    if rg -q -- "$pattern" "$PROJECT_ROOT/$file"; then
        fail "$description"
    else
        pass "$description"
    fi
}

assert_contains_literal() {
    local file="$1"
    local text="$2"
    local description="$3"

    if rg -Fq -- "$text" "$PROJECT_ROOT/$file"; then
        pass "$description"
    else
        fail "$description"
    fi
}

assert_not_exists() {
    local path="$1"
    local description="$2"

    if [[ -e "$PROJECT_ROOT/$path" ]]; then
        fail "$description"
    else
        pass "$description"
    fi
}

check_syntax() {
    if bash -n "$@"; then
        pass "全部 Bash 脚本语法有效"
    else
        fail "全部 Bash 脚本语法有效"
    fi
}

check_menu_metadata() {
    local script
    local function_name
    local priority

    for script in "$PROJECT_ROOT"/modules/*.sh "$PROJECT_ROOT"/softwares/*.sh "$PROJECT_ROOT"/configs/*.sh; do
        function_name=$(awk -F'"' '/^MENU_FUNC=/{print $2; exit}' "$script")

        if [[ -z "$function_name" ]]; then
            fail "$(basename "$script") 声明 MENU_FUNC"
        elif rg -q "^function $function_name\(\)" "$script"; then
            pass "$(basename "$script") 的 MENU_FUNC 可调用"
        else
            fail "$(basename "$script") 的 MENU_FUNC 可调用"
        fi

        priority=$(bash -c 'source "$1/lib/utils.sh"; get_priority "$2"' _ "$PROJECT_ROOT" "$script")
        if [[ "$priority" =~ ^[0-9]+$ ]]; then
            pass "$(basename "$script") 的 PRIORITY 可解析"
        else
            fail "$(basename "$script") 的 PRIORITY 可解析"
        fi
    done
}

check_source_safety() {
    local script

    for script in lib/certbot.sh lib/overview.sh lib/services.sh lib/uninstall.sh; do
        if bash -c 'set +e; source "$1"; case "$-" in *e*) exit 1 ;; *) exit 0 ;; esac' _ "$PROJECT_ROOT/$script"; then
            pass "$script source 后不启用 errexit"
        else
            fail "$script source 后不启用 errexit"
        fi
    done
}

check_utils_behavior() {
    if bash -c 'source "$1"; is_number 42 && ! is_number 4a && function_exists is_number' _ "$PROJECT_ROOT/lib/utils.sh"; then
        pass "公共输入和函数校验可用"
    else
        fail "公共输入和函数校验可用"
    fi

    if bash -c 'source "$1"; missing_menu_function() { return 0; }; call_menu_func missing_menu_function' _ "$PROJECT_ROOT/lib/utils.sh"; then
        pass "菜单函数通过公共调用器执行"
    else
        fail "菜单函数通过公共调用器执行"
    fi

    local clear_error
    clear_error=$(mktemp)
    if TERM=xterm-ghostty bash -c 'source "$1"; clear_screen' _ "$PROJECT_ROOT/lib/utils.sh" \
        > /dev/null 2> "$clear_error" && [[ ! -s "$clear_error" ]]; then
        pass "未知终端类型可静默降级清屏"
    else
        fail "未知终端类型可静默降级清屏"
    fi
    rm -f "$clear_error"
}

check_menu_selector_behavior() {
    if bash -c '
        source "$1/lib/utils.sh"
        export SERVER_CAT_MENU_FORCE_INTERACTIVE=1

        choice=$(printf "\033[B\n" | select_menu "测试菜单" "$BLUE" "返回" "" "第一项" "第二项" 2> /dev/null)
        [[ "$choice" == "2" ]] || exit 1

        choice=$(printf "\033[A\n" | select_menu "测试菜单" "$BLUE" "返回" "" "第一项" "第二项" 2> /dev/null)
        [[ "$choice" == "0" ]] || exit 1

        choice=$(printf "j\n" | select_menu "测试菜单" "$BLUE" "返回" "" "第一项" "第二项" 2> /dev/null)
        [[ "$choice" == "2" ]] || exit 1

        choice=$(printf "2" | select_menu "测试菜单" "$BLUE" "返回" "" "第一项" "第二项" 2> /dev/null)
        [[ "$choice" == "2" ]] || exit 1

        choice=$(printf "\033" | select_menu "测试菜单" "$BLUE" "返回" "" "第一项" "第二项" 2> /dev/null)
        [[ "$choice" == "0" ]] || exit 1

        choice=$(printf "\177" | select_menu "测试菜单" "$BLUE" "返回" "" "第一项" "第二项" 2> /dev/null)
        [[ "$choice" == "0" ]] || exit 1

        choice=$(printf "\b" | select_menu "测试菜单" "$BLUE" "返回" "" "第一项" "第二项" 2> /dev/null)
        [[ "$choice" == "0" ]] || exit 1

        export SERVER_CAT_MENU_DEFAULT_ZERO=1
        choice=$(printf "\n" | select_menu "测试菜单" "$BLUE" "返回" "" "第一项" "第二项" 2> /dev/null)
        [[ "$choice" == "0" ]] || exit 1
        unset SERVER_CAT_MENU_DEFAULT_ZERO

        unset SERVER_CAT_MENU_FORCE_INTERACTIVE
        choice=$(printf "x\n2\n" | select_menu "测试菜单" "$BLUE" "返回" "" "第一项" "第二项" 2> /dev/null)
        [[ "$choice" == "2" ]]
    ' _ "$PROJECT_ROOT"; then
        pass "公共菜单支持方向键、j/k、Enter、Backspace、Esc 与数字输入降级"
    else
        fail "公共菜单支持方向键、j/k、Enter、Backspace、Esc 与数字输入降级"
    fi
}

check_agent_command_behavior() {
    if bash -c 'source "$1/lib/utils.sh"; source "$1/lib/agent.sh"; SERVER_CAT_AGENT_BINARY=/usr/bin/true; server_cat_agent_dispatch check' _ "$PROJECT_ROOT"; then
        pass "Agent 子命令通过独立分发层执行"
    else
        fail "Agent 子命令通过独立分发层执行"
    fi

    if bash -c 'source "$1/lib/utils.sh"; source "$1/lib/agent.sh"; SERVER_CAT_AGENT_BINARY=/usr/bin/true; server_cat_agent_dispatch test-telegram' _ "$PROJECT_ROOT"; then
        pass "Agent Telegram 测试命令通过独立分发层执行"
    else
        fail "Agent Telegram 测试命令通过独立分发层执行"
    fi

    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/lib/agent.sh"
        server_cat_agent_config_menu() { printf "%s\n" configured; }
        [[ "$(server_cat_agent_dispatch conf)" == "configured" ]] &&
            ! server_cat_agent_dispatch configure > /dev/null 2>&1
    ' _ "$PROJECT_ROOT"; then
        pass "Agent 配置命令通过独立分发层执行"
    else
        fail "Agent 配置命令通过独立分发层执行"
    fi

    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/lib/agent.sh"
        journalctl() { printf "%s\n" "$*"; }
        [[ "$(server_cat_agent_dispatch logs)" == "--unit server-cat-agent.service --lines 100 --no-pager" ]] &&
            [[ "$(server_cat_agent_dispatch logs --follow)" == *"--unit server-cat-agent.service --follow"* ]]
    ' _ "$PROJECT_ROOT"; then
        pass "Agent 日志命令支持最近日志与持续跟踪"
    else
        fail "Agent 日志命令支持最近日志与持续跟踪"
    fi

    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/lib/agent.sh"
        journalctl() { return 0; }
        ! server_cat_agent_dispatch logs --unknown > /dev/null
    ' _ "$PROJECT_ROOT"; then
        pass "Agent 日志命令拒绝未知参数"
    else
        fail "Agent 日志命令拒绝未知参数"
    fi
}

check_agent_config_behavior() {
    local config_root
    local config_file
    local config_mode

    config_root=$(mktemp -d)
    config_file="$config_root/agent.toml"
    cp "$PROJECT_ROOT/templates/agent.toml.example" "$config_file"

    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/lib/agent_config.sh"
        config_file="$2"
        server_cat_agent_config_set "$config_file" thresholds memory_warning_percent 91 &&
            [[ "$(server_cat_agent_config_read "$config_file" thresholds memory_warning_percent)" == "91" ]] &&
            [[ "$(server_cat_agent_config_toml_array "nginx, docker")" == "[\"nginx\", \"docker\"]" ]] &&
            server_cat_agent_config_set "$config_file" telegram chat_ids "[\"-1001234567890\"]" &&
            [[ "$(server_cat_agent_config_read "$config_file" telegram chat_ids)" == "[\"-1001234567890\"]" ]]
    ' _ "$PROJECT_ROOT" "$config_file"; then
        pass "Agent 配置向导可安全更新字段并生成 TOML 数组"
    else
        fail "Agent 配置向导可安全更新字段并生成 TOML 数组"
    fi

    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/lib/agent_config.sh"
        marker="$2/docker-menu-step"
        docker() {
            printf "web\tUp 2 hours (healthy)\nredis\tExited (0) 1 hour ago\n"
        }
        select_menu() {
            if [[ ! -e "$marker" ]]; then
                : > "$marker"
                printf "1\n"
            else
                printf "5\n"
            fi
        }
        server_cat_agent_config_select_docker_containers "redis" > /dev/null &&
            [[ "$SERVER_CAT_AGENT_CONFIG_VALUE" == "web,redis" ]]
    ' _ "$PROJECT_ROOT" "$config_root"; then
        pass "Agent 配置向导可自动发现并多选 Docker 容器"
    else
        fail "Agent 配置向导可自动发现并多选 Docker 容器"
    fi

    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/lib/agent_config.sh"
        docker() { return 1; }
        server_cat_agent_config_select_docker_containers "redis" > /dev/null &&
            [[ "$SERVER_CAT_AGENT_CONFIG_VALUE" == "redis" ]]
    ' _ "$PROJECT_ROOT"; then
        pass "Docker 不可用时配置向导保持原巡检目标"
    else
        fail "Docker 不可用时配置向导保持原巡检目标"
    fi

    config_mode=$(stat -c '%a' "$config_file" 2>/dev/null || stat -f '%Lp' "$config_file" 2>/dev/null)
    if [[ "$config_mode" == "600" ]]; then
        pass "Agent 配置向导保持配置权限为 0600"
    else
        fail "Agent 配置向导保持配置权限为 0600"
    fi

    cp "$PROJECT_ROOT/templates/agent.toml.example" "$config_file"
    cp "$config_file" "$config_root/original.toml"
    cp "$config_file" "$config_root/staged.toml"
    server_cat_agent_config_set_for_test() {
        bash -c '
            source "$1/lib/utils.sh"
            source "$1/lib/agent_config.sh"
            SERVER_CAT_AGENT_CONFIG="$2"
            SERVER_CAT_AGENT_BINARY=/usr/bin/false
            server_cat_agent_config_set "$3" thresholds memory_warning_percent 91
            ! server_cat_agent_config_save "$3" > /dev/null 2>&1
        ' _ "$PROJECT_ROOT" "$config_file" "$config_root/staged.toml"
    }
    if server_cat_agent_config_set_for_test &&
        cmp -s "$config_file" "$config_root/original.toml" &&
        [[ ! -e "$config_root/staged.toml" ]]; then
        pass "Agent 配置校验失败时保留原配置并清理临时文件"
    else
        fail "Agent 配置校验失败时保留原配置并清理临时文件"
    fi

    rm -rf "$config_root"
}

check_overview_behavior() {
    local overview_root

    overview_root=$(mktemp -d)
    printf '%s\n' 'PRETTY_NAME="Test Linux"' > "$overview_root/os-release"
    printf '%s\n' 'MemTotal: 2048000 kB' 'MemAvailable: 1024000 kB' 'SwapTotal: 0 kB' 'SwapFree: 0 kB' > "$overview_root/meminfo"
    printf '%s\n' '0.10 0.20 0.30 1/100 42' > "$overview_root/loadavg"

    if SERVER_CAT_OS_RELEASE_FILE="$overview_root/os-release" \
        SERVER_CAT_MEMINFO_FILE="$overview_root/meminfo" \
        SERVER_CAT_LOADAVG_FILE="$overview_root/loadavg" \
        SERVER_CAT_REBOOT_REQUIRED_FILE="$overview_root/reboot-required" \
        bash -c '
            source "$1/lib/utils.sh"
            source "$1/lib/overview.sh"
            hostname() { [[ "$1" == "-I" ]] && printf "10.0.0.2 " || printf "test.example"; }
            uptime() { printf "up 2 days"; }
            nproc() { printf "4"; }
            uname() { printf "6.8.0-test"; }
            date() { printf "2026-07-26 12:00:00 CST"; }
            df() {
                if [[ "$1" == "-Pi" ]]; then
                    printf "Filesystem Inodes IUsed IFree IUse%% Mounted\n/dev/test 1000 100 900 10%% /\n"
                else
                    printf "Filesystem Size Used Avail Use%% Mounted\n/dev/test 20G 5G 15G 25%% /\n"
                fi
            }
            docker() {
                case "$1 $2 $3" in
                    "info  ") return 0 ;;
                    "ps --quiet ") printf "one\n" ;;
                    "ps --all --quiet") printf "one\ntwo\n" ;;
                    "ps --filter health=unhealthy") printf "two\n" ;;
                esac
            }
            systemctl() {
                case "$1" in
                    --failed) printf "failed.service loaded failed failed\n" ;;
                    cat) return 0 ;;
                    is-enabled) printf "enabled\n" ;;
                    is-active) printf "active\n" ;;
                esac
            }
            ss() { printf "tcp LISTEN\n"; }
            output=$(server_cat_overview)
            [[ "$output" == *"Test Linux"* ]] &&
                [[ "$output" == *"50.0% (1000/2000 MiB)"* ]] &&
                [[ "$output" == *"运行 1 / 总计 2，异常健康状态 1"* ]] &&
                [[ "$output" == *"enabled (active)"* ]]
        ' _ "$PROJECT_ROOT"; then
        pass "服务器概览汇总系统、资源、Docker 与 Agent 状态"
    else
        fail "服务器概览汇总系统、资源、Docker 与 Agent 状态"
    fi

    rm -rf "$overview_root"
}

check_service_manager_behavior() {
    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/lib/services.sh"
        systemctl() {
            if [[ "$1" == "list-units" ]]; then
                printf "nginx.service loaded active running Nginx\n"
            elif [[ "$1" == "is-active" ]]; then
                printf "active\n"
            fi
        }
        select_menu() { printf "1\n"; }
        server_cat_service_select running > /dev/null &&
            [[ "$SERVER_CAT_SELECTED_SERVICE" == "nginx.service" ]]
    ' _ "$PROJECT_ROOT"; then
        pass "systemd 服务管理可筛选并选择单个服务"
    else
        fail "systemd 服务管理可筛选并选择单个服务"
    fi

    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/lib/services.sh"
        confirm() { return 0; }
        systemctl() { [[ "$1 $2" == "restart nginx.service" ]]; }
        server_cat_service_action restart nginx.service > /dev/null &&
            ! server_cat_service_action restart "nginx;reboot.service" > /dev/null 2>&1
    ' _ "$PROJECT_ROOT"; then
        pass "systemd 服务变更需要确认并拒绝无效服务名"
    else
        fail "systemd 服务变更需要确认并拒绝无效服务名"
    fi
}

check_firewall_behavior() {
    if bash -c '
        source "$1/modules/firewall.sh"
        command() {
            if [[ "$1 $2" == "-v sshd" ]]; then
                printf "sshd\n"
                return 0
            fi
            builtin command "$@"
        }
        sshd() { printf "port 2222\n"; }
        [[ "$(server_cat_firewall_detect_ssh_ports)" == "2222" ]]
    ' _ "$PROJECT_ROOT"; then
        pass "防火墙启用前读取 SSH 实际端口"
    else
        fail "防火墙启用前读取 SSH 实际端口"
    fi

    if bash -c '
        source "$1/modules/firewall.sh"
        call_log="$2"
        confirm() { return 0; }
        ufw() { printf "%s\n" "$*" >> "$call_log"; }
        server_cat_firewall_detect_ssh_ports() { printf "22022\n"; }
        server_cat_firewall_enable > /dev/null &&
            [[ "$(sed -n "1p" "$call_log")" == "allow 22022/tcp" ]] &&
            rg -q "^--force enable$" "$call_log"
    ' _ "$PROJECT_ROOT" "$PROJECT_ROOT/.firewall-test-calls"; then
        pass "防火墙先放行实际 SSH 端口再启用"
    else
        fail "防火墙先放行实际 SSH 端口再启用"
    fi
    rm -f "$PROJECT_ROOT/.firewall-test-calls"

    if bash -c '
        source "$1/modules/firewall.sh"
        select_menu() { printf "2\n"; }
        confirm() { return 0; }
        ufw() {
            if [[ "$1 $2" == "status numbered" ]]; then
                printf "[ 1] 22/tcp ALLOW IN Anywhere\n[ 7] 443/tcp ALLOW IN 10.0.0.0/8\n"
            else
                [[ "$*" == "--force delete 7" ]]
            fi
        }
        server_cat_firewall_delete_rule > /dev/null
    ' _ "$PROJECT_ROOT"; then
        pass "防火墙可按当前编号删除单条规则"
    else
        fail "防火墙可按当前编号删除单条规则"
    fi
}

check_proxy_node_behavior() {
    if bash -c '
        source "$1/modules/proxy_node.sh"
        command() { return 1; }
        server_cat_proxy_check_docker && exit 1 || exit 0
    ' _ "$PROJECT_ROOT"; then
        pass "代理节点部署前检查 Docker 是否可用"
    else
        fail "代理节点部署前检查 Docker 是否可用"
    fi

    if bash -c '
        source "$1/modules/proxy_node.sh"
        export SERVER_CAT_PROXY_DIR="$2"
        SERVER_CAT_PROXY_CONFIG="$SERVER_CAT_PROXY_DIR/config.json"
        server_cat_proxy_ensure_config
        server_cat_proxy_inbound_add "{\"tag\":\"scat-reality\",\"protocol\":\"vless\"}"
        server_cat_proxy_inbound_add "{\"tag\":\"scat-hysteria2\",\"protocol\":\"hysteria\"}"
        [[ "$(server_cat_proxy_inbound_count)" == "2" ]]
        [[ "$(server_cat_proxy_inbound_get scat-reality | jq -r .protocol)" == "vless" ]]
        [[ "$(server_cat_proxy_inbound_get scat-reality | jq -r .tag)" == "scat-reality" ]]
        server_cat_proxy_inbound_remove scat-reality
        [[ "$(server_cat_proxy_inbound_count)" == "1" ]]
        [[ "$(server_cat_proxy_inbound_get scat-reality)" == "" ]]
        [[ "$(server_cat_proxy_inbound_get scat-hysteria2 | jq -r .protocol)" == "hysteria" ]]
    ' _ "$PROJECT_ROOT" "$(mktemp -d)"; then
        pass "代理节点按 tag 增删查 inbound"
    else
        fail "代理节点按 tag 增删查 inbound"
    fi

    if bash -c '
        source "$1/modules/proxy_node.sh"
        export SERVER_CAT_PROXY_DIR="$2"
        SERVER_CAT_PROXY_CONFIG="$SERVER_CAT_PROXY_DIR/config.json"
        server_cat_proxy_atomic_write "$SERVER_CAT_PROXY_CONFIG" "{
            \"inbounds\":[
                {\"tag\":\"scat-reality\",\"protocol\":\"vless\",\"port\":443},
                {\"tag\":\"scat-hysteria2\",\"protocol\":\"hysteria\",\"port\":8443,
                 \"streamSettings\":{\"tlsSettings\":{\"certificates\":[{\"certificateFile\":\"/tmp/a.crt\",\"keyFile\":\"/tmp/a.key\"}]}}}
            ],
            \"outbounds\":[]
        }"
        ports=$(server_cat_proxy_compute_port_args)
        rg -q "443:443/tcp" <<< "$ports"
        rg -q "8443:8443/udp" <<< "$ports"
        mounts=$(server_cat_proxy_compute_volume_args)
        rg -q "/tmp/a.crt:/tmp/a.crt:ro" <<< "$mounts"
        rg -q "/tmp/a.key:/tmp/a.key:ro" <<< "$mounts"
    ' _ "$PROJECT_ROOT" "$(mktemp -d)"; then
        pass "代理节点按 inbound 计算端口与证书挂载参数"
    else
        fail "代理节点按 inbound 计算端口与证书挂载参数"
    fi

    if bash -c '
        source "$1/modules/proxy_node.sh"
        export SERVER_CAT_PROXY_DIR="$2"
        SERVER_CAT_PROXY_NODE_JSON="$SERVER_CAT_PROXY_DIR/node.json"
        server_cat_proxy_ensure_node_json
        server_cat_proxy_nodejson_set reality deployed false
        [[ "$(server_cat_proxy_nodejson_get reality deployed)" == "false" ]]
        server_cat_proxy_nodejson_set reality deployed true
        server_cat_proxy_nodejson_set reality port 443
        server_cat_proxy_nodejson_set reality uuid "abc-123"
        [[ "$(server_cat_proxy_nodejson_get reality deployed)" == "true" ]]
        [[ "$(server_cat_proxy_nodejson_get reality port)" == "443" ]]
        [[ "$(server_cat_proxy_nodejson_get reality uuid)" == "abc-123" ]]
    ' _ "$PROJECT_ROOT" "$(mktemp -d)"; then
        pass "代理节点状态按字段读写 node.json"
    else
        fail "代理节点状态按字段读写 node.json"
    fi
}

check_ssh_key_behavior() {
    local ssh_key_root
    local authorized_keys

    ssh_key_root=$(mktemp -d)
    authorized_keys="$ssh_key_root/authorized_keys"
    printf '%s\n' 'ssh-ed25519 AAAA first@example' 'ssh-ed25519 BBBB second@example' > "$authorized_keys"

    if bash -c '
        source "$1/modules/ssh_keys.sh"
        ssh-keygen() { [[ "$1" == "-lf" ]]; }
        server_cat_ssh_key_validate "ssh-ed25519 AAAA test@example" &&
            ! server_cat_ssh_key_validate $'"'"'ssh-ed25519 AAAA test\nsecond'"'"'
    ' _ "$PROJECT_ROOT"; then
        pass "SSH 公钥管理使用 ssh-keygen 校验单行公钥"
    else
        fail "SSH 公钥管理使用 ssh-keygen 校验单行公钥"
    fi

    if bash -c '
        source "$1/modules/ssh_keys.sh"
        ssh-keygen() { printf "256 SHA256:test fingerprint (ED25519)\n"; }
        select_menu() { printf "2\n"; }
        confirm() { return 0; }
        server_cat_ssh_key_remove "$2" "$(id -u)" "$(id -g)" > /dev/null &&
            [[ "$(wc -l < "$2" | tr -d " ")" == "1" ]] &&
            rg -q "first@example" "$2" &&
            ! rg -q "second@example" "$2"
    ' _ "$PROJECT_ROOT" "$authorized_keys"; then
        pass "SSH 公钥管理每次只撤销选中的一条授权"
    else
        fail "SSH 公钥管理每次只撤销选中的一条授权"
    fi

    rm -rf "$ssh_key_root"
}

check_system_identity_behavior() {
    if bash -c '
        source "$1/modules/system_identity.sh"
        server_cat_hostname_valid server-01.example.com &&
            server_cat_hostname_valid localhost &&
            ! server_cat_hostname_valid "-bad" &&
            ! server_cat_hostname_valid "bad..name" &&
            ! server_cat_hostname_valid "bad_name"
    ' _ "$PROJECT_ROOT"; then
        pass "基础系统设置严格校验主机名"
    else
        fail "基础系统设置严格校验主机名"
    fi

    if bash -c '
        source "$1/modules/system_identity.sh"
        timedatectl() {
            if [[ "$1" == "list-timezones" ]]; then
                printf "Asia/Shanghai\nAsia/Tokyo\nEurope/London\n"
            else
                [[ "$1 $2" == "set-timezone Asia/Shanghai" ]]
            fi
        }
        select_menu() { printf "1\n"; }
        confirm() { return 0; }
        server_cat_system_identity_select_timezone <<< "Shanghai" > /dev/null
    ' _ "$PROJECT_ROOT"; then
        pass "基础系统设置从系统时区列表筛选后修改"
    else
        fail "基础系统设置从系统时区列表筛选后修改"
    fi

    if bash -c '
        source "$1/modules/system_identity.sh"
        confirm() { return 0; }
        timedatectl() { [[ "$1 $2" == "set-ntp true" ]]; }
        server_cat_system_identity_set_ntp true > /dev/null
    ' _ "$PROJECT_ROOT"; then
        pass "基础系统设置通过 timedatectl 管理 NTP"
    else
        fail "基础系统设置通过 timedatectl 管理 NTP"
    fi
}

check_swap_behavior() {
    local swap_root
    local fstab_file

    swap_root=$(mktemp -d)
    fstab_file="$swap_root/fstab"
    printf '%s\n' '/dev/root / ext4 defaults 0 1' "$swap_root/swapfile none swap sw 0 0" > "$fstab_file"

    if SERVER_CAT_SWAP_FILE="$swap_root/swapfile" SERVER_CAT_FSTAB_FILE="$fstab_file" bash -c '
        source "$1/modules/swap.sh"
        server_cat_swap_update_fstab enable &&
            [[ "$(rg -c "^[^#]*swapfile none swap sw 0 0$" "$2")" == "1" ]] &&
            server_cat_swap_update_fstab disable &&
            ! rg -q "swapfile" "$2" &&
            rg -q "^/dev/root " "$2"
    ' _ "$PROJECT_ROOT" "$fstab_file"; then
        pass "Swap 管理原子更新 fstab 且不重复写入"
    else
        fail "Swap 管理原子更新 fstab 且不重复写入"
    fi

    if bash -c '
        source "$1/modules/swap.sh"
        server_cat_swap_size_valid 1 && server_cat_swap_size_valid 64 &&
            ! server_cat_swap_size_valid 0 && ! server_cat_swap_size_valid 65 &&
            ! server_cat_swap_size_valid 2G
    ' _ "$PROJECT_ROOT"; then
        pass "Swap 管理限制文件大小范围"
    else
        fail "Swap 管理限制文件大小范围"
    fi

    rm -rf "$swap_root"
}

check_release_behavior() {
    if bash "$PROJECT_ROOT/tests/release_checks.sh"; then
        pass "签名发布源检查验证有效清单并拒绝路径穿越"
    else
        fail "签名发布源检查验证有效清单并拒绝路径穿越"
    fi
}

check_legacy_layout_migration_behavior() {
    local migration_root

    migration_root=$(mktemp -d)
    mkdir -p "$migration_root/releases/0.1.0"
    printf '%s\n' "0.1.0" > "$migration_root/releases/0.1.0/VERSION"
    ln -s "releases/0.1.0" "$migration_root/current"

    if SERVER_CAT_INSTALL_ROOT="$migration_root" \
        bash -c '
            source "$1/lib/utils.sh"
            source "$1/lib/release.sh"
            server_cat_release_migrate_legacy_layout > /dev/null &&
                [[ "$SERVER_CAT_LEGACY_LAYOUT_MIGRATED" -eq 1 ]] &&
                [[ -d "$SERVER_CAT_INSTALL_ROOT/current" ]] &&
                [[ ! -L "$SERVER_CAT_INSTALL_ROOT/current" ]] &&
                [[ ! -e "$SERVER_CAT_INSTALL_ROOT/releases" ]] &&
                [[ "$(server_cat_installed_version)" == "0.1.0" ]]
        ' _ "$PROJECT_ROOT"; then
        pass "旧版发布目录可自动迁移为单一安装目录"
    else
        fail "旧版发布目录可自动迁移为单一安装目录"
    fi

    rm -rf "$migration_root"
}

check_update_menu_behavior() {
    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/configs/check_update.sh"
        server_cat_update_check() { SERVER_CAT_UPDATE_AVAILABLE=1; }
        server_cat_update_apply() { printf "%s\\n" applied; }
        confirm() { return 0; }
        [[ "$(update_server_cat)" == *"applied" ]]
    ' _ "$PROJECT_ROOT"; then
        pass "菜单更新在验签后确认并安装"
    else
        fail "菜单更新在验签后确认并安装"
    fi

    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/configs/check_update.sh"
        server_cat_update_check() { SERVER_CAT_UPDATE_AVAILABLE=1; }
        server_cat_update_apply() { exit 1; }
        confirm() { return 1; }
        update_server_cat
    ' _ "$PROJECT_ROOT" > /dev/null; then
        pass "取消菜单更新不会安装版本"
    else
        fail "取消菜单更新不会安装版本"
    fi

    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/configs/check_update.sh"
        server_cat_update_check() { SERVER_CAT_UPDATE_AVAILABLE=0; }
        server_cat_update_apply() { exit 1; }
        update_server_cat
    ' _ "$PROJECT_ROOT" > /dev/null; then
        pass "菜单在已是最新版本时不会请求安装"
    else
        fail "菜单在已是最新版本时不会请求安装"
    fi
}

check_doctor_behavior() {
    local doctor_root

    doctor_root=$(mktemp -d)
    mkdir -p "$doctor_root/install/current" "$doctor_root/etc"
    printf '%s\n' "0.1.0" > "$doctor_root/install/current/VERSION"
    printf '%s\n' '#!/bin/bash' 'exit 0' > "$doctor_root/server-cat-agent"
    chmod 0755 "$doctor_root/server-cat-agent"
    printf '%s\n' '[agent]' > "$doctor_root/etc/agent.toml"
    chmod 0600 "$doctor_root/etc/agent.toml"

    if SERVER_CAT_INSTALL_ROOT="$doctor_root/install" \
        SERVER_CAT_AGENT_BINARY="$doctor_root/server-cat-agent" \
        SERVER_CAT_AGENT_CONFIG="$doctor_root/etc/agent.toml" \
        bash -c '
            source "$1/lib/utils.sh"
            source "$1/lib/release.sh"
            source "$1/lib/certbot.sh"
            source "$1/lib/doctor.sh"
            curl() { :; }
            gpgv() { :; }
            jq() { :; }
            sha256sum() { :; }
            tar() { :; }
            zstd() { :; }
            systemctl() {
                case "$1" in
                    cat) return 0 ;;
                    is-enabled) printf "%s\\n" disabled; return 0 ;;
                    is-active) printf "%s\\n" inactive; return 3 ;;
                esac
            }
            server_cat_certbot_is_installed() { return 1; }
            server_cat_update_check() { SERVER_CAT_UPDATE_AVAILABLE=0; }
            server_cat_doctor
        ' _ "$PROJECT_ROOT" > /dev/null; then
        pass "doctor 可验证完整运行环境"
    else
        fail "doctor 可验证完整运行环境"
    fi

    rm -rf "$doctor_root"
}

check_certbot_renewal_behavior() {
    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/lib/certbot.sh"
        systemctl() {
            case "$1" in
                cat) return 0 ;;
                is-enabled) printf "%s\n" enabled ;;
                is-active) printf "%s\n" active ;;
            esac
        }
        server_cat_certbot_refresh_renew_timer_status &&
            [[ "$SERVER_CAT_CERTBOT_TIMER_PRESENT" -eq 1 ]] &&
            [[ "$SERVER_CAT_CERTBOT_TIMER_ENABLED" == "enabled" ]] &&
            [[ "$SERVER_CAT_CERTBOT_TIMER_ACTIVE" == "active" ]]
    ' _ "$PROJECT_ROOT"; then
        pass "Certbot 自动续期检查识别正常运行的 Snap timer"
    else
        fail "Certbot 自动续期检查识别正常运行的 Snap timer"
    fi

    if bash -c '
        source "$1/softwares/install_certbot.sh"
        server_cat_certbot_refresh_renew_timer_status() {
            SERVER_CAT_CERTBOT_TIMER_PRESENT=0
            SERVER_CAT_CERTBOT_TIMER_ENABLED="未知"
            SERVER_CAT_CERTBOT_TIMER_ACTIVE="未知"
            return 1
        }
        output=$(server_cat_certbot_verify_auto_renewal)
        [[ "$output" == *"未找到 Certbot 自动续期任务"* ]] &&
            [[ "$output" == *"不会创建额外的 cron"* ]]
    ' _ "$PROJECT_ROOT"; then
        pass "Certbot 安装验证在续期 timer 缺失时给出明确提醒"
    else
        fail "Certbot 安装验证在续期 timer 缺失时给出明确提醒"
    fi

    if bash -c '
        source "$1/softwares/install_certbot.sh"
        server_cat_certbot_refresh_renew_timer_status() {
            SERVER_CAT_CERTBOT_TIMER_PRESENT=1
            SERVER_CAT_CERTBOT_TIMER_ENABLED=disabled
            SERVER_CAT_CERTBOT_TIMER_ACTIVE=inactive
            return 1
        }
        output=$(server_cat_certbot_verify_auto_renewal)
        [[ "$output" == *"disabled (inactive)"* ]]
    ' _ "$PROJECT_ROOT"; then
        pass "Certbot 安装验证在续期 timer 停用时报告状态"
    else
        fail "Certbot 安装验证在续期 timer 停用时报告状态"
    fi

    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/lib/certbot.sh"
        source "$1/lib/doctor.sh"
        SERVER_CAT_DOCTOR_WARNING_COUNT=0
        server_cat_certbot_is_installed() { return 1; }
        output=$(server_cat_doctor_check_certbot_renewal)
        [[ "$output" == *"未安装 Certbot，跳过"* ]] &&
            [[ "$SERVER_CAT_DOCTOR_WARNING_COUNT" -eq 0 ]]
    ' _ "$PROJECT_ROOT"; then
        pass "doctor 在未安装 Certbot 时跳过续期检查"
    else
        fail "doctor 在未安装 Certbot 时跳过续期检查"
    fi

    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/lib/certbot.sh"
        source "$1/lib/doctor.sh"
        SERVER_CAT_DOCTOR_WARNING_COUNT=0
        server_cat_certbot_is_installed() { return 0; }
        server_cat_certbot_refresh_renew_timer_status() {
            SERVER_CAT_CERTBOT_TIMER_PRESENT=1
            SERVER_CAT_CERTBOT_TIMER_ENABLED=enabled
            SERVER_CAT_CERTBOT_TIMER_ACTIVE=active
            return 0
        }
        output=$(server_cat_doctor_check_certbot_renewal)
        [[ "$output" == *"自动续期任务已启用并运行中"* ]] &&
            [[ "$SERVER_CAT_DOCTOR_WARNING_COUNT" -eq 0 ]]
    ' _ "$PROJECT_ROOT"; then
        pass "doctor 在已安装 Certbot 时报告自动续期状态"
    else
        fail "doctor 在已安装 Certbot 时报告自动续期状态"
    fi
}

check_config_source_behavior() {
    if bash -c '
        source_dir="/server-cat-root"
        SCRIPT_DIR="$source_dir"
        source "$1/configs/check_update.sh"
        source "$1/configs/doctor.sh"
        source "$1/configs/cleanup.sh"
        source "$1/configs/agent_config.sh"
        [[ "$SCRIPT_DIR" == "$source_dir" ]]
    ' _ "$PROJECT_ROOT"; then
        pass "配置菜单加载不会覆盖主入口目录"
    else
        fail "配置菜单加载不会覆盖主入口目录"
    fi
}

check_cleanup_behavior() {
    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/lib/cleanup.sh"
        call_log="$(mktemp)"
        export SERVER_CAT_CLEANUP_CALL_LOG="$call_log"
        systemd-tmpfiles() { printf "%s\\n" "$*" >> "$SERVER_CAT_CLEANUP_CALL_LOG"; }
        confirm() { return 0; }
        server_cat_cleanup_temp > /dev/null &&
            grep -Fx -- "--clean --dry-run" "$call_log" > /dev/null &&
            grep -Fx -- "--clean" "$call_log" > /dev/null
    ' _ "$PROJECT_ROOT"; then
        pass "临时文件清理先检查再按系统规则执行"
    else
        fail "临时文件清理先检查再按系统规则执行"
    fi

    if bash -c '
        source "$1/lib/utils.sh"
        source "$1/lib/cleanup.sh"
        docker() { printf "%s\\n" "$*"; }
        confirm_strong() { [[ "$1" == "CLEAN" ]]; }
        output="$(server_cat_cleanup_docker_dangling_images)"
        [[ "$output" == *"image prune --force"* && "$output" != *"volume prune"* && "$output" != *"system prune"* ]]
    ' _ "$PROJECT_ROOT"; then
        pass "Docker 镜像清理不涉及卷或全量清理"
    else
        fail "Docker 镜像清理不涉及卷或全量清理"
    fi
}

check_uninstall_behavior() {
    local uninstall_root
    local call_log

    uninstall_root=$(mktemp -d)
    call_log=$(mktemp)
    mkdir -p \
        "$uninstall_root/opt/server-cat/current" \
        "$uninstall_root/etc/systemd/system" \
        "$uninstall_root/etc/systemd/system/timers.target.wants" \
        "$uninstall_root/usr/local/sbin" \
        "$uninstall_root/usr/share/bash-completion/completions" \
        "$uninstall_root/etc/server-cat" \
        "$uninstall_root/var/lib/server-cat"
    touch \
        "$uninstall_root/etc/systemd/system/server-cat-agent.service" \
        "$uninstall_root/etc/systemd/system/server-cat-agent.timer" \
        "$uninstall_root/usr/share/bash-completion/completions/scat" \
        "$uninstall_root/etc/server-cat/agent.toml" \
        "$uninstall_root/var/lib/server-cat/alerts.json"
    ln -s ../server-cat-agent.timer \
        "$uninstall_root/etc/systemd/system/timers.target.wants/server-cat-agent.timer"
    printf '%s\n' '#!/bin/bash' 'exec /opt/server-cat/current/main.sh "$@"' \
        > "$uninstall_root/usr/local/sbin/scat"
    cp "$uninstall_root/usr/local/sbin/scat" "$uninstall_root/usr/local/sbin/server-cat"

    if SERVER_CAT_UNINSTALL_ROOT="$uninstall_root" \
        SERVER_CAT_UNINSTALL_CALL_LOG="$call_log" \
        bash -c '
            source "$1/lib/utils.sh"
            source "$1/lib/uninstall.sh"
            systemctl() {
                printf "%s\n" "$*" >> "$SERVER_CAT_UNINSTALL_CALL_LOG"
                [[ "$1" != "is-active" ]]
            }
            server_cat_uninstall_execute 0 > /dev/null
        ' _ "$PROJECT_ROOT" &&
        [[ ! -e "$uninstall_root/opt/server-cat" ]] &&
        [[ ! -e "$uninstall_root/etc/systemd/system/server-cat-agent.service" ]] &&
        [[ ! -e "$uninstall_root/etc/systemd/system/server-cat-agent.timer" ]] &&
        [[ ! -e "$uninstall_root/etc/systemd/system/timers.target.wants/server-cat-agent.timer" &&
            ! -L "$uninstall_root/etc/systemd/system/timers.target.wants/server-cat-agent.timer" ]] &&
        [[ ! -e "$uninstall_root/usr/local/sbin/scat" ]] &&
        [[ ! -e "$uninstall_root/usr/local/sbin/server-cat" ]] &&
        [[ ! -e "$uninstall_root/usr/share/bash-completion/completions/scat" ]] &&
        [[ -f "$uninstall_root/etc/server-cat/agent.toml" ]] &&
        [[ -f "$uninstall_root/var/lib/server-cat/alerts.json" ]] &&
        grep -Fx "disable --now server-cat-agent.timer" "$call_log" > /dev/null &&
        grep -Fx "stop server-cat-agent.service" "$call_log" > /dev/null &&
        grep -Fx "daemon-reload" "$call_log" > /dev/null; then
        pass "自卸载停止 Agent 并删除程序组件，默认保留配置和状态"
    else
        fail "自卸载停止 Agent 并删除程序组件，默认保留配置和状态"
    fi

    if SERVER_CAT_UNINSTALL_ROOT="$uninstall_root" \
        bash -c '
            source "$1/lib/utils.sh"
            source "$1/lib/uninstall.sh"
            systemctl() {
                [[ "$1" != "is-active" ]]
            }
            server_cat_uninstall_execute 1 > /dev/null
        ' _ "$PROJECT_ROOT" &&
        [[ ! -e "$uninstall_root/etc/server-cat" ]] &&
        [[ ! -e "$uninstall_root/var/lib/server-cat" ]]; then
        pass "强确认模式可额外删除 Server Cat 配置和状态"
    else
        fail "强确认模式可额外删除 Server Cat 配置和状态"
    fi

    mkdir -p "$uninstall_root/opt/server-cat/current" "$uninstall_root/usr/local/sbin"
    printf '%s\n' '#!/bin/bash' 'exec /other/tool "$@"' \
        > "$uninstall_root/usr/local/sbin/scat"
    if SERVER_CAT_UNINSTALL_ROOT="$uninstall_root" \
        bash -c '
            source "$1/lib/utils.sh"
            source "$1/lib/uninstall.sh"
            systemctl() {
                [[ "$1" != "is-active" ]]
            }
            server_cat_uninstall_execute 0 > /dev/null
        ' _ "$PROJECT_ROOT" &&
        [[ -f "$uninstall_root/usr/local/sbin/scat" ]]; then
        pass "自卸载不会删除非 Server Cat 管理的同名命令"
    else
        fail "自卸载不会删除非 Server Cat 管理的同名命令"
    fi

    mkdir -p "$uninstall_root/opt/server-cat/current"
    if SERVER_CAT_UNINSTALL_ROOT="$uninstall_root" \
        bash -c '
            source "$1/lib/utils.sh"
            source "$1/lib/uninstall.sh"
            systemctl() {
                if [[ "$1" == "is-active" && "$3" == "server-cat-agent.timer" ]]; then
                    return 0
                fi
                return 1
            }
            ! server_cat_uninstall_execute 0 > /dev/null
        ' _ "$PROJECT_ROOT" &&
        [[ -d "$uninstall_root/opt/server-cat/current" ]]; then
        pass "Agent 无法停止时自卸载在删除文件前中止"
    else
        fail "Agent 无法停止时自卸载在删除文件前中止"
    fi

    rm -rf "$uninstall_root"
    rm -f "$call_log"
}

check_completion_behavior() {
    if bash -c 'source "$1"; COMP_WORDS=(scat agent ""); COMP_CWORD=2; _scat_completion; [[ " ${COMPREPLY[*]} " == *" check "* && " ${COMPREPLY[*]} " == *" status "* && " ${COMPREPLY[*]} " == *" logs "* && " ${COMPREPLY[*]} " == *" conf "* && " ${COMPREPLY[*]} " != *" configure "* && " ${COMPREPLY[*]} " == *" test-email "* && " ${COMPREPLY[*]} " == *" test-telegram "* && " ${COMPREPLY[*]} " == *" mute "* && " ${COMPREPLY[*]} " == *" unmute "* ]]' _ "$PROJECT_ROOT/packaging/completions/scat.bash"; then
        pass "scat 补全提供 Agent 子命令"
    else
        fail "scat 补全提供 Agent 子命令"
    fi

    if bash -c 'source "$1"; COMP_WORDS=(scat agent logs ""); COMP_CWORD=3; _scat_completion; [[ " ${COMPREPLY[*]} " == *" --follow "* ]]' _ "$PROJECT_ROOT/packaging/completions/scat.bash"; then
        pass "scat 补全提供日志持续跟踪参数"
    else
        fail "scat 补全提供日志持续跟踪参数"
    fi

    if bash -c 'source "$1"; COMP_WORDS=(scat update ""); COMP_CWORD=2; _scat_completion; [[ " ${COMPREPLY[*]} " == *" rollback "* ]]' _ "$PROJECT_ROOT/packaging/completions/scat.bash"; then
        fail "scat 补全不再提供回退命令"
    else
        pass "scat 补全不再提供回退命令"
    fi

    if bash -c 'source "$1"; COMP_WORDS=(scat update ""); COMP_CWORD=2; _scat_completion; [[ " ${COMPREPLY[*]} " == *" check "* && " ${COMPREPLY[*]} " == *" apply "* ]]' _ "$PROJECT_ROOT/packaging/completions/scat.bash"; then
        pass "scat 补全提供检查与安装更新命令"
    else
        fail "scat 补全提供检查与安装更新命令"
    fi
}

check_platform_behavior() {
    if bash "$PROJECT_ROOT/tests/platform_checks.sh"; then
        pass "发行版兼容层识别支持范围并拒绝未验证系统"
    else
        fail "发行版兼容层识别支持范围并拒绝未验证系统"
    fi
}

check_syntax \
    "$PROJECT_ROOT/main.sh" \
    "$PROJECT_ROOT"/lib/*.sh \
    "$PROJECT_ROOT/packaging/install.sh" \
    "$PROJECT_ROOT"/modules/*.sh \
    "$PROJECT_ROOT"/softwares/*.sh \
    "$PROJECT_ROOT"/configs/*.sh \
    "$PROJECT_ROOT"/scripts/*.sh
check_menu_metadata
check_source_safety
check_utils_behavior
check_menu_selector_behavior
check_agent_command_behavior
check_agent_config_behavior
check_overview_behavior
check_service_manager_behavior
check_firewall_behavior
check_proxy_node_behavior
check_ssh_key_behavior
check_system_identity_behavior
check_swap_behavior
check_release_behavior
check_legacy_layout_migration_behavior
check_update_menu_behavior
check_doctor_behavior
check_certbot_renewal_behavior
check_config_source_behavior
check_cleanup_behavior
check_uninstall_behavior
check_completion_behavior
check_platform_behavior

assert_not_contains "configs/check_update.sh" 'reset --hard' "自更新不强制丢弃本地修改"
assert_not_contains "configs/check_update.sh" 'git -C' "生产更新不再依赖 Git 仓库"
assert_contains_literal "configs/check_update.sh" 'server_cat_update_check' "菜单更新复用签名发布源"
assert_contains_literal "configs/check_update.sh" 'server_cat_update_apply' "菜单更新可安装已验证版本"
assert_contains_literal "configs/check_update.sh" 'confirm "已完成更新验证，是否立即安装"' "菜单更新安装前要求确认"
assert_contains_literal "configs/doctor.sh" 'server_cat_doctor' "菜单提供运行环境检查"
assert_contains_literal "configs/cleanup.sh" 'server_cat_cleanup_menu' "菜单提供空间清理"
assert_contains_literal "configs/agent_config.sh" 'server_cat_agent_config_menu' "菜单提供 Agent 配置向导"
assert_contains_literal "configs/service_manager.sh" 'server_cat_service_manager_menu' "菜单提供 systemd 服务管理"
assert_contains_literal "main.sh" 'show_uninstall_menu' "主菜单区分 Server Cat 自卸载与单项恢复"
assert_contains_literal "main.sh" 'show_component_rollback_menu' "系统组件仅允许逐项恢复或卸载"
assert_not_contains "main.sh" 'ROLLBACK_BATCH_MODE' "卸载菜单不再批量执行全部回滚函数"
assert_contains_literal "lib/uninstall.sh" 'systemctl disable --now server-cat-agent.timer' "自卸载停止并禁用 Agent 定时器"
assert_contains_literal "lib/uninstall.sh" 'server_cat_uninstall_remove_directory "$install_root"' "自卸载删除 Server Cat 程序目录"
assert_contains_literal "lib/uninstall.sh" '已保留配置目录' "自卸载默认保留配置和状态"
assert_contains_literal "main.sh" 'scat doctor' "命令行提供运行环境检查"
assert_contains_literal "main.sh" 'scat status' "命令行提供服务器概览"
assert_contains_literal "main.sh" 'server_cat_overview' "主菜单提供服务器概览"
assert_contains_literal "main.sh" 'scat agent conf' "命令行提供 Agent 配置向导"
assert_not_contains "main.sh" 'scat agent configure' "命令行不再提供冗长的 Agent 配置命令"
assert_contains_literal "main.sh" 'scat agent logs --follow' "命令行提供 Agent 巡检日志查看"
assert_contains_literal "lib/agent_config.sh" '"查看巡检日志"' "Agent 菜单提供巡检日志查看"
assert_contains_literal "main.sh" 'scat agent test-telegram' "命令行提供 Telegram 测试通知"
assert_contains_literal "lib/agent_config.sh" 'server_cat_agent_config_telegram' "Agent 菜单提供 Telegram 配置"
assert_contains_literal "lib/cleanup.sh" 'systemd-tmpfiles --clean' "临时文件清理使用系统规则"
assert_not_contains "lib/cleanup.sh" 'docker volume prune' "空间清理不删除 Docker 卷"
assert_not_contains "lib/cleanup.sh" 'docker system prune' "空间清理不执行 Docker 全量清理"
assert_not_contains "README.md" 'update rollback' "用户文档不再提供版本回退"
assert_not_contains "main.sh" 'server_cat_update_rollback' "命令行不再保留版本回退"
assert_not_contains "packaging/completions/scat.bash" 'rollback' "补全不再包含版本回退"
assert_not_contains "lib/release.sh" 'server_cat_update_rollback' "在线更新不再保留版本回退"
assert_contains_literal "main.sh" 'dispatch_command "$@"' "主入口在菜单前分发子命令"
assert_contains_literal "main.sh" 'server_cat_agent_dispatch "${@:2}"' "主入口委托 Agent 子命令分发"
assert_contains_literal "packaging/install.sh" 'for command_name in scat server-cat' "首次安装提供 scat 与兼容命令"
assert_contains_literal "lib/release.sh" 'for command_name in scat server-cat' "更新安装提供 scat 与兼容命令"
assert_contains_literal "scripts/build-release.sh" 'packaging/completions/scat.bash' "发布包包含 scat 补全规则"
assert_contains_literal "scripts/build-release.sh" 'main.sh lib configs templates modules softwares scripts' "发布包包含运行配置模板"
assert_contains_literal "scripts/build-release.sh" 'README.md LICENSE' "发布包包含说明与 MIT 许可证"
assert_not_exists "backups" "项目不再包含备份与恢复子系统"
assert_not_exists "lib/backup_tools.sh" "项目不再包含备份归档工具"
assert_not_contains "main.sh" '数据备份' "主菜单不再提供数据备份入口"
assert_not_contains "main.sh" 'show_backup_menu' "主入口不再加载备份菜单"
assert_contains_literal "main.sh" '"服务器概览" "常用软件" "常用设置" "系统设置" "卸载与恢复"' "主菜单提供五个有效入口"
assert_not_contains "lib/utils.sh" 'get_backup_func' "公共工具不再解析备份钩子"
assert_not_exists "modules/init_user_dirs.sh" "项目不再创建个人化用户目录"
assert_not_exists "modules/certbot_renew.sh" "项目不再维护自定义 Certbot 续期模块"
assert_not_exists "scripts/certbot-renew.sh" "发布包不再携带自定义 Certbot 续期脚本"
assert_not_contains "modules/ssh_config.sh" 'BACKUP_FUNC' "SSH 模块不再声明备份钩子"
assert_contains_literal "modules/ssh_keys.sh" 'ssh-keygen -lf' "SSH 公钥写入前验证指纹"
assert_not_contains "modules/ssh_keys.sh" 'private' "SSH 公钥管理不处理私钥"
assert_contains_literal "modules/system_identity.sh" 'timedatectl list-timezones' "基础系统设置使用系统时区列表"
assert_contains_literal "modules/system_identity.sh" 'hostnamectl set-hostname' "基础系统设置通过 hostnamectl 修改主机名"
assert_contains_literal "modules/swap.sh" 'confirm_strong "SWAP"' "Swap 创建或调整需要强确认"
assert_contains_literal "modules/swap.sh" 'confirm_strong "REMOVE"' "Swap 删除需要强确认"
assert_contains_literal "modules/swap.sh" 'truncate -s "${size_gib}G"' "Swap 调整后固定文件精确大小"
assert_not_contains "modules/swap.sh" 'swapoff -a' "Swap 管理不批量停用其他交换空间"
assert_not_contains "modules/firewall.sh" 'ufw allow ssh' "防火墙不再固定放行 22 端口"
assert_not_contains "modules/firewall.sh" 'ufw allow http' "防火墙不再默认开放 HTTP"
assert_contains_literal "modules/firewall.sh" 'ufw status numbered' "防火墙支持读取编号规则"
assert_not_contains "softwares/install_docker.sh" 'BACKUP_FUNC' "Docker 模块不再声明备份钩子"
assert_not_contains "softwares/install_nginx.sh" 'BACKUP_FUNC' "Nginx 模块不再声明备份钩子"
assert_not_contains "softwares/install_certbot.sh" 'BACKUP_FUNC' "Certbot 模块不再声明备份钩子"
assert_not_contains "softwares/install_certbot.sh" 'setup_certbot_renew' "Certbot 安装不再配置自定义续期任务"
assert_not_contains "softwares/install_certbot.sh" 'crontab' "Certbot 安装不再修改用户 crontab"
assert_contains_literal "softwares/install_certbot.sh" 'server_cat_certbot_verify_auto_renewal' "Certbot 安装后验证 Snap 自动续期任务"
assert_contains_literal "softwares/install_ncdu.sh" 'apt-get install -y ncdu' "Ncdu 使用系统软件源安装"
assert_contains_literal "softwares/install_ncdu.sh" 'apt-get remove -y ncdu' "Ncdu 支持单项卸载"
assert_contains_literal "lib/doctor.sh" 'server_cat_doctor_check_certbot_renewal' "doctor 检查 Certbot 自动续期任务"
assert_contains_literal "packaging/install.sh" 'bash-completion' "首次安装部署 Bash 补全"
assert_contains_literal "lib/release.sh" 'bash-completion' "更新安装部署 Bash 补全"
assert_contains_literal "packaging/install.sh" 'templates/agent.toml.example' "首次安装从模板创建 Agent 配置"
assert_contains_literal "lib/release.sh" 'templates/agent.toml.example' "更新从模板创建 Agent 配置"
assert_not_contains "packaging/install.sh" 'smtp.env' "首次安装不再创建独立 SMTP 配置"
assert_not_contains "lib/release.sh" 'smtp.env' "更新不再创建独立 SMTP 配置"
assert_not_contains "packaging/systemd/server-cat-agent.service" 'EnvironmentFile' "Agent 服务不依赖独立 SMTP 配置"
assert_contains_literal "templates/agent.toml.example" 'smtp_host = ""' "Agent 模板包含 SMTP 配置"
assert_contains_literal "templates/agent.toml.example" '[telegram]' "Agent 模板包含 Telegram 配置"
assert_contains_literal "templates/agent.toml.example" 'bot_token = ""' "Agent 模板不预置 Telegram Bot Token"
assert_contains_literal "LICENSE" 'MIT License' "仓库包含 MIT 许可证正文"
assert_contains_literal "README.md" '[MIT License](LICENSE)' "README 链接实际许可证文件"
assert_contains_literal "lib/release.sh" 'gpgv --keyring' "更新检查使用独立公钥验证签名"
assert_contains_literal "lib/release.sh" "--proto '=https'" "更新检查仅允许 HTTPS 发布源"
assert_contains "modules/ssh_config.sh" 'restart_ssh_service' "SSH 配置复用服务重启回退"
assert_contains_literal "main.sh" 'is_number "$choice"' "菜单在数值比较前校验输入"
assert_contains_literal "main.sh" 'call_menu_func "$func"' "菜单通过安全调用器执行功能"
assert_contains_literal "lib/utils.sh" 'clear_screen' "菜单使用兼容未知终端的清屏函数"
assert_contains_literal "main.sh" 'select_menu "$icon $title"' "软件与设置菜单使用公共选择器"
assert_contains_literal "main.sh" 'select_menu "⚙️  系统设置"' "系统设置菜单使用公共选择器"
assert_contains_literal "lib/agent_config.sh" 'choice=$(select_menu' "Agent 菜单使用公共选择器"
assert_contains_literal "lib/cleanup.sh" 'choice=$(select_menu' "空间清理菜单使用公共选择器"
printf '\n检查完成：%s 项，失败 %s 项。\n' "$CHECK_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -ne 0 ]]; then
    exit 1
fi
