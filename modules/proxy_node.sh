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

    mkdir -p "$(dirname "$target")"
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

# nodejson_set <proto> <field> <value>
# value 为数字/布尔/字符串；字符串会自动加引号
server_cat_proxy_nodejson_set() {
    local proto="$1"
    local field="$2"
    local value="$3"
    local raw
    local tmp

    server_cat_proxy_ensure_node_json
    case "$value" in
        true|false) raw="$value" ;;
        ''|*[!0-9-]*) raw=$(jq -R . <<< "$value") ;;
        *) raw="$value" ;;
    esac

    tmp=$(mktemp "$(dirname "$SERVER_CAT_PROXY_NODE_JSON")/.node.XXXXXX") || return 1
    if ! jq --arg p "$proto" --arg f "$field" --argjson v "$raw" \
        '.[$p][$f] = $v' "$SERVER_CAT_PROXY_NODE_JSON" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 0600 "$tmp"
    mv "$tmp" "$SERVER_CAT_PROXY_NODE_JSON"
}

# nodejson_get <proto> <field>，输出原始值（字符串无引号）
# 注意：不能用 `// empty`，否则 false 布尔值会被当 falsy 丢弃
server_cat_proxy_nodejson_get() {
    local proto="$1"
    local field="$2"

    [[ -f "$SERVER_CAT_PROXY_NODE_JSON" ]] || return 0
    jq -r --arg p "$proto" --arg f "$field" '
        .[$p] | if has($f) then (.[$f] | if type == "boolean" then tostring else (. // "") end) else "" end
    ' "$SERVER_CAT_PROXY_NODE_JSON" 2>/dev/null
}

# 等待容器 Running 且至少一个 inbound 端口在监听
server_cat_proxy_health_check() {
    local proto port check

    if ! docker ps --format '{{.Names}}' 2>/dev/null |
        grep -qx "$SERVER_CAT_PROXY_CONTAINER"; then
        print_error "容器 $SERVER_CAT_PROXY_CONTAINER 未运行"
        return 1
    fi

    server_cat_proxy_config_exists || return 0
    while IFS=$'\t' read -r proto port; do
        [[ -z "$port" ]] && continue
        if [[ "$proto" == "hysteria" ]]; then
            check="udp"
        else
            check="tcp"
        fi
        if ! ss -l${check}n 2>/dev/null | awk -v p=":$port" '$2 ~ p { found=1 } END { exit !found }'; then
            print_warning "端口 $port/$check 暂未监听，容器可能仍在启动"
            return 1
        fi
    done < <(jq -r '.inbounds[]? | select(.port) | [.protocol, (.port|tostring)] | @tsv' \
        "$SERVER_CAT_PROXY_CONFIG" 2>/dev/null)
    return 0
}

server_cat_proxy_write_link_file() {
    local content="$1"
    server_cat_proxy_atomic_write "$SERVER_CAT_PROXY_LINK_FILE" "$content" 0600
}

# 通过临时 xray 容器生成 UUID
server_cat_proxy_gen_uuid() {
    docker run --rm "$SERVER_CAT_PROXY_IMAGE" xray uuid 2>/dev/null | tr -d '[:space:]'
}

# 通过临时 xray 容器生成 x25519 密钥对，输出 "priv\tpub"
server_cat_proxy_gen_x25519() {
    local output priv pub

    output=$(docker run --rm "$SERVER_CAT_PROXY_IMAGE" xray x25519 2>/dev/null)
    priv=$(printf '%s\n' "$output" | awk -F': ' '/Private key/{print $2}')
    pub=$(printf '%s\n' "$output" | awk -F': ' '/Public key/{print $2}')
    printf '%s\t%s\n' "$priv" "$pub"
}

# 生成 8 位与 16 位十六进制 shortId，输出两行
server_cat_proxy_gen_short_ids() {
    printf '%s\n' "$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf '%s\n' "$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
}

# 生成 Reality 参数 JSON（供落 node.json），不含 deployed 字段
# 参数: port dest uuid priv pub short1 short2
server_cat_proxy_reality_params_json() {
    jq -n \
        --argjson port "$1" \
        --arg dest "$2" \
        --arg uuid "$3" \
        --arg priv "$4" \
        --arg pub "$5" \
        --arg s1 "$6" \
        --arg s2 "$7" \
        '{port:$port, dest:$dest, serverName:($dest|sub(":.*";"")), uuid:$uuid,
          privateKey:$priv, publicKey:$pub, shortIds:[$s1,$s2]}'
}

# 生成 Reality inbound JSON（含 tag）
# 参数: port dest
server_cat_proxy_gen_reality_config() {
    local port="$1"
    local dest="$2"
    local host="${dest%%:*}"
    local uuid priv pub short1 short2 params_json

    uuid=$(server_cat_proxy_gen_uuid)
    IFS=$'\t' read -r priv pub < <(server_cat_proxy_gen_x25519)
    { read -r short1; read -r short2; } < <(server_cat_proxy_gen_short_ids)

    # 把参数写入临时文件供部署后落 node.json（路径基于可被测试覆盖的 NODE_JSON 派生）
    server_cat_proxy_init_dirs
    local _params_dir
    _params_dir=$(dirname "$SERVER_CAT_PROXY_NODE_JSON")
    server_cat_proxy_reality_params_json "$port" "$dest" "$uuid" "$priv" "$pub" "$short1" "$short2" > \
        "$_params_dir/.reality.params.tmp"
    chmod 0600 "$_params_dir/.reality.params.tmp"

    jq -n \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg priv "$priv" \
        --arg pub "$pub" \
        --arg dest "$dest" \
        --arg host "$host" \
        --arg s1 "$short1" \
        --arg s2 "$short2" \
        '{
            tag: "scat-reality",
            listen: "0.0.0.0",
            port: $port,
            protocol: "vless",
            settings: { clients: [{ id: $uuid, flow: "xtls-rprx-vision" }], decryption: "none" },
            streamSettings: {
                network: "tcp",
                security: "reality",
                realitySettings: {
                    show: false,
                    dest: $dest,
                    xver: 0,
                    serverNames: [$host],
                    privateKey: $priv,
                    publicKey: $pub,
                    shortIds: [$s1, $s2],
                    settings: { fingerprint: "chrome", serverName: $host, spiderX: "" }
                }
            }
        }'
}

# 参数: ip port dest uuid pubkey sid
server_cat_proxy_gen_reality_link() {
    local ip="$1" port="$2" dest="$3" uuid="$4" pub="$5" sid="${6:-}"
    local host="${dest%%:*}"

    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&host=%s&headerType=none#SCat-Reality\n' \
        "$uuid" "$ip" "$port" "$host" "$pub" "$sid" "$host"
}

server_cat_proxy_gen_password() {
    openssl rand -base64 24 2>/dev/null | tr -d '[:space:]'
}

# 参数: ip port serverName password
server_cat_proxy_gen_hysteria2_link() {
    local ip="$1" port="$2" sni="$3" pass="$4"

    printf 'hysteria2://%s@%s:%s?sni=%s&insecure=0#SCat-Hysteria2\n' \
        "$pass" "$ip" "$port" "$sni"
}

# 参数: port serverName crt key password
server_cat_proxy_gen_hysteria2_config() {
    local port="$1" sni="$2" crt="$3" key="$4" pass="$5"

    jq -n \
        --argjson port "$port" \
        --arg sni "$sni" \
        --arg crt "$crt" \
        --arg key "$key" \
        --arg pass "$pass" \
        '{
            tag: "scat-hysteria2",
            listen: "::",
            port: $port,
            protocol: "hysteria",
            settings: { version: 2, clients: [{ auth: $pass }] },
            streamSettings: {
                network: "tcp",
                security: "tls",
                tlsSettings: {
                    serverName: $sni,
                    alpn: ["h3"],
                    certificates: [{ certificateFile: $crt, keyFile: $key, usage: "encipherment" }]
                }
            }
        }'
}

# 按 node.json 当前状态重新拼出所有已部署节点的链接并写回 share-link.txt
server_cat_proxy_refresh_link_file() {
    local links=""
    local ip port dest uuid pub sid sni pass

    ip=$(server_cat_proxy_detect_public_ip)

    if [[ "$(server_cat_proxy_nodejson_get reality deployed)" == "true" ]]; then
        port=$(server_cat_proxy_nodejson_get reality port)
        dest=$(server_cat_proxy_nodejson_get reality dest)
        uuid=$(server_cat_proxy_nodejson_get reality uuid)
        pub=$(server_cat_proxy_nodejson_get reality publicKey)
        sid=$(server_cat_proxy_nodejson_get reality shortIds | jq -r '.[0]' 2>/dev/null)
        links+=$(server_cat_proxy_gen_reality_link "$ip" "$port" "$dest" "$uuid" "$pub" "$sid")
        links+=$'\n'
    fi

    if [[ "$(server_cat_proxy_nodejson_get hysteria2 deployed)" == "true" ]]; then
        port=$(server_cat_proxy_nodejson_get hysteria2 port)
        sni=$(server_cat_proxy_nodejson_get hysteria2 serverName)
        pass=$(server_cat_proxy_nodejson_get hysteria2 password)
        links+=$(server_cat_proxy_gen_hysteria2_link "$ip" "$port" "$sni" "$pass")
        links+=$'\n'
    fi

    server_cat_proxy_write_link_file "$links"
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
server_cat_proxy_deploy_reality() {
    local port dest_choice dest inbound_json ip uuid pub short1 link

    server_cat_proxy_check_docker || return 1

    if [[ "$(server_cat_proxy_nodejson_get reality deployed)" == "true" ]]; then
        print_warning "VLESS + Reality 节点已部署，请先卸载"
        return 0
    fi

    read -r -p "监听端口（默认 443）: " port
    port="${port:-443}"
    if ! is_number "$port" || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        print_error "端口必须是 1 到 65535 的整数"
        return 1
    fi

    dest_choice=$(select_menu "选择 Reality 伪装目标" "$BLUE" "取消" \
        "伪装目标必须支持 TLS1.3 与 X25519。" \
        "www.microsoft.com:443" \
        "www.cloudflare.com:443" \
        "www.amazon.com:443" \
        "aws.amazon.com:443" \
        "www.samsung.com:443" \
        "www.nvidia.com:443" \
        "www.amd.com:443" \
        "www.intel.com:443" \
        "www.sony.com:443" \
        "dl.google.com:443")
    case "$dest_choice" in
        1) dest="www.microsoft.com:443" ;;
        2) dest="www.cloudflare.com:443" ;;
        3) dest="www.amazon.com:443" ;;
        4) dest="aws.amazon.com:443" ;;
        5) dest="www.samsung.com:443" ;;
        6) dest="www.nvidia.com:443" ;;
        7) dest="www.amd.com:443" ;;
        8) dest="www.intel.com:443" ;;
        9) dest="www.sony.com:443" ;;
        10) dest="dl.google.com:443" ;;
        *) print_info "已取消"; return 0 ;;
    esac

    print_info "正在生成 UUID 与 x25519 密钥对（需拉取 Xray 镜像，首次较慢）..."
    inbound_json=$(server_cat_proxy_gen_reality_config "$port" "$dest")
    if [[ -z "$inbound_json" ]]; then
        print_error "Reality 配置生成失败"
        rm -f "$(dirname "$SERVER_CAT_PROXY_NODE_JSON")/.reality.params.tmp"
        return 1
    fi

    if ! server_cat_proxy_inbound_add "$inbound_json"; then
        print_error "写入 config.json 失败"
        rm -f "$(dirname "$SERVER_CAT_PROXY_NODE_JSON")/.reality.params.tmp"
        return 1
    fi

    print_info "正在重建 Xray 容器..."
    if ! server_cat_proxy_rebuild_container; then
        print_error "容器重建失败，回滚配置"
        server_cat_proxy_inbound_remove scat-reality
        rm -f "$(dirname "$SERVER_CAT_PROXY_NODE_JSON")/.reality.params.tmp"
        return 1
    fi

    sleep 1
    server_cat_proxy_health_check || print_warning "健康检查未通过，请检查端口是否被占用；配置已保留，可手动排查"

    # 落 node.json：把 params 与 deployed:true 合并到 reality 节点
    local _params_file
    _params_file="$(dirname "$SERVER_CAT_PROXY_NODE_JSON")/.reality.params.tmp"
    if [[ -f "$_params_file" ]]; then
        local params_json merge_tmp
        params_json=$(cat "$_params_file")
        server_cat_proxy_ensure_node_json
        merge_tmp=$(mktemp "$(dirname "$SERVER_CAT_PROXY_NODE_JSON")/.merge.XXXXXX")
        if jq --argjson params "$params_json" '.reality = ($params + {deployed:true})' \
            "$SERVER_CAT_PROXY_NODE_JSON" > "$merge_tmp"; then
            chmod 0600 "$merge_tmp"
            mv "$merge_tmp" "$SERVER_CAT_PROXY_NODE_JSON"
        else
            rm -f "$merge_tmp"
        fi
        rm -f "$_params_file"
    fi

    ip=$(server_cat_proxy_detect_public_ip)
    uuid=$(server_cat_proxy_nodejson_get reality uuid)
    pub=$(server_cat_proxy_nodejson_get reality publicKey)
    short1=$(server_cat_proxy_nodejson_get reality shortIds | jq -r '.[0]' 2>/dev/null)
    link=$(server_cat_proxy_gen_reality_link "$ip" "$port" "$dest" "$uuid" "$pub" "$short1")

    server_cat_proxy_write_link_file "$link"
    print_step "部署成功"
    print_info "伪装目标: $dest"
    print_success "分享链接："
    printf '%s\n' "$link"
}
server_cat_proxy_deploy_hysteria2() {
    local port sni crt key pass inbound_json ip link

    server_cat_proxy_check_docker || return 1

    if [[ "$(server_cat_proxy_nodejson_get hysteria2 deployed)" == "true" ]]; then
        print_warning "Hysteria2 节点已部署，请先卸载"
        return 0
    fi

    read -r -p "监听端口（默认 443）: " port
    port="${port:-443}"
    if ! is_number "$port" || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        print_error "端口必须是 1 到 65535 的整数"
        return 1
    fi

    read -r -p "TLS 证书 SNI（如 example.com）: " sni
    [[ -z "$sni" ]] && { print_error "SNI 不能为空"; return 1; }
    read -r -p "证书文件路径（.crt）: " crt
    read -r -p "私钥文件路径（.key）: " key
    if [[ ! -f "$crt" || -L "$crt" ]]; then
        print_error "证书文件不存在或为符号链接: $crt"
        return 1
    fi
    if [[ ! -f "$key" || -L "$key" ]]; then
        print_error "私钥文件不存在或为符号链接: $key"
        return 1
    fi

    pass=$(server_cat_proxy_gen_password)
    inbound_json=$(server_cat_proxy_gen_hysteria2_config "$port" "$sni" "$crt" "$key" "$pass")

    if ! server_cat_proxy_inbound_add "$inbound_json"; then
        print_error "写入 config.json 失败"
        return 1
    fi

    print_info "正在重建 Xray 容器..."
    if ! server_cat_proxy_rebuild_container; then
        print_error "容器重建失败，回滚配置"
        server_cat_proxy_inbound_remove scat-hysteria2
        return 1
    fi

    sleep 1
    server_cat_proxy_health_check || print_warning "健康检查未通过，请排查端口占用"

    server_cat_proxy_nodejson_set hysteria2 deployed true
    server_cat_proxy_nodejson_set hysteria2 port "$port"
    server_cat_proxy_nodejson_set hysteria2 serverName "$sni"
    server_cat_proxy_nodejson_set hysteria2 certFile "$crt"
    server_cat_proxy_nodejson_set hysteria2 keyFile "$key"
    server_cat_proxy_nodejson_set hysteria2 password "$pass"

    ip=$(server_cat_proxy_detect_public_ip)
    link=$(server_cat_proxy_gen_hysteria2_link "$ip" "$port" "$sni" "$pass")
    server_cat_proxy_refresh_link_file

    print_step "部署成功"
    print_info "SNI: $sni"
    print_success "分享链接："
    printf '%s\n' "$link"
}
server_cat_proxy_show() {
    server_cat_proxy_ensure_node_json
    print_step "已部署节点"

    if [[ "$(server_cat_proxy_nodejson_get reality deployed)" == "true" ]]; then
        print_info "VLESS + Reality"
        printf '  %-12s %s\n' "端口:" "$(server_cat_proxy_nodejson_get reality port)"
        printf '  %-12s %s\n' "伪装目标:" "$(server_cat_proxy_nodejson_get reality dest)"
    else
        print_info "VLESS + Reality：未部署"
    fi

    if [[ "$(server_cat_proxy_nodejson_get hysteria2 deployed)" == "true" ]]; then
        print_info "Hysteria2"
        printf '  %-12s %s\n' "端口:" "$(server_cat_proxy_nodejson_get hysteria2 port)"
        printf '  %-12s %s\n' "SNI:" "$(server_cat_proxy_nodejson_get hysteria2 serverName)"
    else
        print_info "Hysteria2：未部署"
    fi

    if [[ "$(server_cat_proxy_nodejson_get reality deployed)" == "true" ]] || \
       [[ "$(server_cat_proxy_nodejson_get hysteria2 deployed)" == "true" ]]; then
        server_cat_proxy_refresh_link_file
        print_step "分享链接"
        cat "$SERVER_CAT_PROXY_LINK_FILE" 2>/dev/null
        print_info "链接同时保存在 $SERVER_CAT_PROXY_LINK_FILE"
    fi
}

server_cat_proxy_remove_reality() {
    if [[ "$(server_cat_proxy_nodejson_get reality deployed)" != "true" ]]; then
        print_warning "VLESS + Reality 节点未部署"
        return 0
    fi

    print_warning "将卸载 VLESS + Reality 节点并从 config.json 移除对应 inbound"
    confirm_strong "REMOVE" "确认卸载 Reality 节点" || {
        print_info "已取消"
        return 0
    }

    server_cat_proxy_inbound_remove scat-reality

    if [[ "$(server_cat_proxy_inbound_count)" -gt 0 ]]; then
        server_cat_proxy_rebuild_container
    else
        docker stop "$SERVER_CAT_PROXY_CONTAINER" > /dev/null 2>&1 || true
        docker rm -f "$SERVER_CAT_PROXY_CONTAINER" > /dev/null 2>&1 || true
    fi

    server_cat_proxy_nodejson_set reality deployed false
    server_cat_proxy_refresh_link_file
    print_success "VLESS + Reality 节点已卸载"
}
server_cat_proxy_remove_hysteria2() {
    if [[ "$(server_cat_proxy_nodejson_get hysteria2 deployed)" != "true" ]]; then
        print_warning "Hysteria2 节点未部署"
        return 0
    fi

    print_warning "将卸载 Hysteria2 节点并从 config.json 移除对应 inbound"
    confirm_strong "REMOVE" "确认卸载 Hysteria2 节点" || {
        print_info "已取消"
        return 0
    }

    server_cat_proxy_inbound_remove scat-hysteria2

    if [[ "$(server_cat_proxy_inbound_count)" -gt 0 ]]; then
        server_cat_proxy_rebuild_container
    else
        docker stop "$SERVER_CAT_PROXY_CONTAINER" > /dev/null 2>&1 || true
        docker rm -f "$SERVER_CAT_PROXY_CONTAINER" > /dev/null 2>&1 || true
    fi

    server_cat_proxy_nodejson_set hysteria2 deployed false
    server_cat_proxy_refresh_link_file
    print_success "Hysteria2 节点已卸载"
}

rollback_proxy_node() {
    print_warning "将卸载代理节点模块：停止并删除 Xray 容器，删除 /etc/server-cat/proxy 配置目录"
    print_warning "不会删除已下载的 Xray 镜像"
    confirm_strong "REMOVE" "确认回滚代理节点模块" || {
        print_info "已取消"
        return 0
    }

    if docker ps -a --format '{{.Names}}' 2>/dev/null |
        grep -qx "$SERVER_CAT_PROXY_CONTAINER"; then
        docker stop "$SERVER_CAT_PROXY_CONTAINER" > /dev/null 2>&1 || true
        docker rm -f "$SERVER_CAT_PROXY_CONTAINER" > /dev/null 2>&1 || true
    fi

    rm -rf "$SERVER_CAT_PROXY_DIR"
    print_success "代理节点模块已回滚"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    configure_proxy_node
fi
