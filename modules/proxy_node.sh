#!/bin/bash

MENU_NAME="部署代理节点"
MENU_FUNC="configure_proxy_node"
ROLLBACK_FUNC="rollback_proxy_node"
PRIORITY=30

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"

SERVER_CAT_PROXY_DIR="${SERVER_CAT_PROXY_DIR:-/etc/server-cat/proxy}"
SERVER_CAT_PROXY_XRAY_DIR="$SERVER_CAT_PROXY_DIR/xray"
SERVER_CAT_PROXY_CONFIG="$SERVER_CAT_PROXY_XRAY_DIR/config.json"
SERVER_CAT_PROXY_NODE_JSON="$SERVER_CAT_PROXY_XRAY_DIR/node.json"
SERVER_CAT_PROXY_LINK_FILE="$SERVER_CAT_PROXY_XRAY_DIR/share-link.txt"
SERVER_CAT_PROXY_CONTAINER="server-cat-xray"
SERVER_CAT_PROXY_IMAGE="teddysun/xray:26.7.11"

server_cat_proxy_check_docker() {
    if ! command -v docker > /dev/null 2>&1; then
        print_error "Docker 未安装，请先在「常用软件」中安装 Docker"
        return 1
    fi
    if ! docker info > /dev/null 2>&1; then
        print_error "Docker 守护进程未运行"
        return 1
    fi
    return 0
}

server_cat_proxy_init_dirs() {
    install -d -m 0755 "$SERVER_CAT_PROXY_DIR"
    install -d -m 0755 "$SERVER_CAT_PROXY_XRAY_DIR"
}

server_cat_proxy_atomic_write() {
    local target="$1"
    local content="$2"
    local mode="${3:-0600}"
    local tmp

    tmp=$(mktemp "$(dirname "$target")/.proxy.XXXXXX") || return 1
    if ! printf '%s' "$content" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod "$mode" "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$target"
}

server_cat_proxy_detect_public_ip() {
    local ip

    ip=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    if [[ -n "$ip" ]]; then
        printf '%s\n' "$ip"
        return 0
    fi

    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -n "$ip" ]]; then
        printf '%s\n' "$ip"
        return 0
    fi

    hostname 2>/dev/null
}

server_cat_proxy_config_exists() {
    [[ -f "$SERVER_CAT_PROXY_CONFIG" ]]
}

# 确保空 config.json 存在；已有则保留
server_cat_proxy_ensure_config() {
    server_cat_proxy_init_dirs
    if server_cat_proxy_config_exists; then
        return 0
    fi
    server_cat_proxy_atomic_write "$SERVER_CAT_PROXY_CONFIG" \
        '{"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"}]}'
}

server_cat_proxy_ensure_node_json() {
    server_cat_proxy_init_dirs
    if [[ -f "$SERVER_CAT_PROXY_NODE_JSON" ]]; then
        return 0
    fi
    server_cat_proxy_atomic_write "$SERVER_CAT_PROXY_NODE_JSON" \
        '{"reality":{"deployed":false},"hysteria2":{"deployed":false}}'
}

# 按 tag 读取整个 inbound 对象，不存在输出空串
server_cat_proxy_inbound_get() {
    local tag="$1"

    server_cat_proxy_config_exists || return 0
    jq -c --arg t "$tag" '.inbounds[] | select(.tag == $t)' "$SERVER_CAT_PROXY_CONFIG" 2>/dev/null
}

server_cat_proxy_inbound_count() {
    server_cat_proxy_config_exists || { printf '0\n'; return 0; }
    jq '.inbounds | length' "$SERVER_CAT_PROXY_CONFIG" 2>/dev/null
}

# inbound_json 是单个 inbound 对象的 JSON 字符串（含 tag）
server_cat_proxy_inbound_add() {
    local inbound_json="$1"
    local tmp

    server_cat_proxy_ensure_config
    tmp=$(mktemp "$(dirname "$SERVER_CAT_PROXY_CONFIG")/.inbound.XXXXXX") || return 1
    if ! jq --argjson nb "$inbound_json" \
        '(.inbounds // []) |= (. | map(select(.tag != $nb.tag)) + [$nb])' \
        "$SERVER_CAT_PROXY_CONFIG" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 0600 "$tmp"
    mv "$tmp" "$SERVER_CAT_PROXY_CONFIG"
}

server_cat_proxy_inbound_remove() {
    local tag="$1"
    local tmp

    server_cat_proxy_config_exists || return 0
    tmp=$(mktemp "$(dirname "$SERVER_CAT_PROXY_CONFIG")/.inbound.XXXXXX") || return 1
    if ! jq --arg t "$tag" '.inbounds |= map(select(.tag != $t))' \
        "$SERVER_CAT_PROXY_CONFIG" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 0600 "$tmp"
    mv "$tmp" "$SERVER_CAT_PROXY_CONFIG"
}

# 输出多行 "-p host:container/proto" 参数；协议无 port 字段则跳过
server_cat_proxy_compute_port_args() {
    server_cat_proxy_config_exists || return 0
    jq -r '
        .inbounds[]?
        | select(.port)
        | (.protocol) as $p
        | (.port) as $port
        | (if $p == "hysteria" then "udp" else "tcp" end) as $proto
        | "-p \($port):\($port)/\($proto)"
    ' "$SERVER_CAT_PROXY_CONFIG" 2>/dev/null
}

# 输出多行 "-v src:dst:ro" 参数，从 hysteria inbound 的 tls 证书路径推导
server_cat_proxy_compute_volume_args() {
    local cert key

    server_cat_proxy_config_exists || return 0
    while IFS=$'\t' read -r cert key; do
        [[ -n "$cert" ]] && printf -- '-v %s:%s:ro\n' "$cert" "$cert"
        [[ -n "$key" ]] && printf -- '-v %s:%s:ro\n' "$key" "$key"
    done < <(jq -r '
        .inbounds[]?
        | select(.protocol == "hysteria")
        | .streamSettings.tlsSettings.certificates[]?
        | [.certificateFile // "", .keyFile // ""]
        | @tsv
    ' "$SERVER_CAT_PROXY_CONFIG" 2>/dev/null)
}

server_cat_proxy_rebuild_container() {
    local -a port_args
    local -a volume_args
    local line

    while IFS= read -r line; do
        [[ -n "$line" ]] && port_args+=("$line")
    done < <(server_cat_proxy_compute_port_args)

    while IFS= read -r line; do
        [[ -n "$line" ]] && volume_args+=("$line")
    done < <(server_cat_proxy_compute_volume_args)

    docker rm -f "$SERVER_CAT_PROXY_CONTAINER" > /dev/null 2>&1 || true

    docker run -d \
        --name "$SERVER_CAT_PROXY_CONTAINER" \
        --restart unless-stopped \
        -v "$SERVER_CAT_PROXY_CONFIG:/etc/xray/config.json:ro" \
        "${volume_args[@]}" \
        "${port_args[@]}" \
        "$SERVER_CAT_PROXY_IMAGE" > /dev/null
}

function configure_proxy_node() {
    local choice

    while true; do
        choice=$(select_menu \
            "部署代理节点" \
            "$BLUE" \
            "返回常用设置" \
            "通过 Docker 单容器运行 Xray，支持 VLESS+Reality 与 Hysteria2。" \
            "部署 VLESS + Reality 节点" \
            "部署 Hysteria2 节点" \
            "查看已部署节点" \
            "卸载 VLESS + Reality 节点" \
            "卸载 Hysteria2 节点")

        case "$choice" in
            1) server_cat_proxy_deploy_reality ;;
            2) server_cat_proxy_deploy_hysteria2 ;;
            3) server_cat_proxy_show ;;
            4) server_cat_proxy_remove_reality ;;
            5) server_cat_proxy_remove_hysteria2 ;;
            0) break ;;
            *) print_error "无效输入，请重试" ;;
        esac

        print_step "请按 [Enter] 键继续..."
        read -r
    done
}

# 占位实现，后续 Task 填充
server_cat_proxy_deploy_reality() { return 0; }
server_cat_proxy_deploy_hysteria2() { return 0; }
server_cat_proxy_show() { return 0; }
server_cat_proxy_remove_reality() { return 0; }
server_cat_proxy_remove_hysteria2() { return 0; }

rollback_proxy_node() {
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    configure_proxy_node
fi
