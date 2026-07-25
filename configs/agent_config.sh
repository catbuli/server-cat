#!/bin/bash

MENU_NAME="配置监控 Agent"
MENU_FUNC="configure_server_cat_agent"
PRIORITY=25

AGENT_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$AGENT_CONFIG_DIR/../lib/utils.sh"
source "$AGENT_CONFIG_DIR/../lib/agent.sh"
source "$AGENT_CONFIG_DIR/../lib/agent_config.sh"

function configure_server_cat_agent() {
    server_cat_agent_config_menu
}
