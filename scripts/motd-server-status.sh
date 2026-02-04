#!/bin/bash
# MOTD 服务器状态显示脚本
# 部署位置: /etc/update-motd.d/92-server-status

# 只在有终端时显示
if [ "$TERM" = "dumb" ] || [ -z "$TERM" ]; then
    exit 0
fi

# 颜色定义
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "${YELLOW}【防火墙】${NC}"
if command -v ufw &> /dev/null; then
    ufw status 2>/dev/null | grep -E "^Status|^  " | head -5
else
    echo "UFW 未安装"
fi

echo ""
echo -e "${YELLOW}【Docker】${NC}"
if command -v docker &> /dev/null; then
    running=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l)
    echo "运行中: $running 个"
    if [ "$running" -gt 0 ]; then
        docker ps --format "  {{.Names}} ({{.Image}})" 2>/dev/null | head -5
        if [ "$running" -gt 5 ]; then
            echo "  ..."
        fi
    fi
else
    echo "未安装"
fi

echo ""
echo -e "${YELLOW}【SSH】${NC}"
ss -tn state established '( dport = :22 or sport = :22 )' 2>/dev/null | wc -l | xargs -I {} echo "活动连接: {}"

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
