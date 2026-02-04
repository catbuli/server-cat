#!/bin/bash
# Certbot 自动续期脚本
# 建议通过 crontab 每周运行一次

set -eo pipefail

LOG_FILE="/var/log/certbot-renew.log"

touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/certbot-renew.log"

{
    echo "=== 证书续期开始 $(date) ==="

    if certbot renew --quiet; then
        echo "✓ 证书续期成功"

        if systemctl is-active --quiet nginx 2>/dev/null; then
            systemctl reload nginx 2>/dev/null && echo "✓ Nginx 已重载"
        fi

        # 重载 apache (如果存在且未使用 nginx)
        if ! systemctl is-active --quiet nginx 2>/dev/null && systemctl is-active --quiet apache2 2>/dev/null; then
            systemctl reload apache2 2>/dev/null && echo "✓ Apache 已重载"
        fi
    else
        echo "✗ 证书续期失败，错误代码: $?"
        exit 1
    fi

    echo "=== 证书续期结束 $(date) ==="
    echo ""
} >> "$LOG_FILE" 2>&1

exit 0
