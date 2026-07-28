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
