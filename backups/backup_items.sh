#!/bin/bash
# 备份项目定义和软件版本清单

# 备份项目清单 - 格式: "类型:源路径:备份名称:描述"
BACKUP_ITEMS=(
    "dir:$HOME/logs:user_logs:用户日志目录"
    "dir:$HOME/dockers:user_dockers:Docker Compose 配置目录"
    "dir:$HOME/configs:user_configs:用户配置文件目录"
    "dir:$HOME/scripts:user_scripts:用户脚本目录"
    "file:/etc/ssh/sshd_config:sshd_config:SSH 服务配置"
    "file:/etc/ssh/sshd_config.d:ssh_config_d:SSH 配置目录"
    "cmd:ufw status numbered:ufw_rules:UFW 防火墙规则"
    "dir:/etc/nginx:nginx_config:Nginx 配置目录"
    "dir:/var/www/html:nginx_html:Nginx 网站根目录"
    "dir:/etc/letsencrypt:certbot_certs:Certbot SSL 证书"
    "file:/etc/crontab:system_crontab:系统定时任务"
    "cmd:crontab -l 2>/dev/null || true:user_crontab:当前用户定时任务"
    "file:/etc/sudoers.d:sudoers_d:Sudoers 配置目录"
    "cmd:docker ps --format '{{.Names}}' 2>/dev/null || true:docker_containers:运行中的容器列表"
    "cmd:docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true:docker_images:Docker 镜像列表"
)

# 软件版本清单 - 格式: "名称:获取命令"
SOFTWARE_VERSIONS=(
    "nginx:nginx -v 2>&1"
    "docker:docker --version"
    "docker-compose:docker compose version"
    "certbot:certbot --version"
    "ufw:ufw --version"
    "openssh:sshd -V 2>&1"
)

# 获取备份项目列表
function get_backup_items() {
    for item in "${BACKUP_ITEMS[@]}"; do
        echo "$item"
    done
}

# 获取软件版本清单
function get_software_list() {
    for item in "${SOFTWARE_VERSIONS[@]}"; do
        echo "$item"
    done
}
