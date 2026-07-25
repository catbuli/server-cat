#!/bin/bash

MENU_NAME="Docker"
MENU_FUNC="install_docker"
ROLLBACK_FUNC="rollback_docker"
PRIORITY=10

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"
source "$SCRIPT_DIR/../lib/platform.sh"

function install_docker() {
    local docker_distribution

    docker_distribution=$(server_cat_platform_docker_distribution) || {
        print_error "当前系统不支持 Docker 官方仓库安装: $(server_cat_platform_description)"
        return 1
    }

    echo "======================================"
    echo "  📦 Docker 安装脚本"
    echo "======================================"

    print_step "[1/8] 移除可能存在的旧版本 Docker..."
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        apt-get remove -y $pkg 2>/dev/null || true
    done

    print_step "[2/8] 更新 apt 包索引..."
    if ! apt-get update -qq; then
        print_error "apt update 失败"
        return 1
    fi

    print_step "[3/8] 安装必要的依赖包..."
    if ! apt-get install -y ca-certificates curl gnupg lsb-release > /dev/null; then
        print_error "依赖包安装失败"
        return 1
    fi

    print_step "[4/8] 添加 Docker 官方 GPG 密钥..."
    install -m 0755 -d /etc/apt/keyrings
    if ! curl -fsSL "https://download.docker.com/linux/$docker_distribution/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; then
        print_error "GPG 密钥获取失败"
        return 1
    fi
    chmod a+r /etc/apt/keyrings/docker.gpg

    print_step "[5/8] 设置 Docker apt 仓库..."
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$docker_distribution \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    print_step "[6/8] 更新 apt 包索引（包含 Docker 仓库）..."
    if ! apt-get update -qq; then
        print_error "apt update 失败"
        return 1
    fi

    print_step "[7/8] 安装 Docker Engine, containerd, 和 Docker Compose..."
    if ! apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null; then
        print_error "Docker 安装失败"
        return 1
    fi

    print_step "[8/8] 启动 Docker 服务..."
    systemctl start docker || true
    systemctl enable docker || true

    echo ""
    print_success "✅ Docker 安装成功！"

    print_info "📊 版本信息："
    docker --version 2>/dev/null || echo "  • Docker: 已安装"
    docker compose version 2>/dev/null || echo "  • Docker Compose: 已安装"

    echo ""

    if confirm "是否配置 Docker 镜像加速" "n"; then
        read -p "请输入镜像地址: " mirror_url

        if [ -n "$mirror_url" ]; then
            mkdir -p /etc/docker
            cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": ["$mirror_url"]
}
EOF
            systemctl restart docker || true
            print_success "✅ 镜像源已配置: $mirror_url"
        fi
    fi

    print_info "📝 使用提示："
    echo "  • 运行测试容器: sudo docker run hello-world"
    echo "  • 查看运行中的容器: sudo docker ps"
    echo "  • 查看 Docker 信息: sudo docker info"
    echo ""
    echo "  • 将用户添加到 docker 组以避免使用 sudo:"
    echo "    sudo usermod -aG docker \$USER"
    echo "    (需要重新登录才能生效)"

    return 0
}

function rollback_docker() {
    print_step "↩️  卸载 Docker..."

    print_warning "⚠️  此操作将卸载 Docker 及所有相关组件"
    print_warning "⚠️  所有容器、镜像和数据卷将被永久删除！"

    confirm_strong "YES" "确认卸载" || {
        print_warning "已取消卸载"
        return 0
    }

    if command -v docker &> /dev/null; then
        print_info "停止所有容器..."
        docker stop $(docker ps -aq) 2>/dev/null || true
        print_info "删除所有容器..."
        docker rm -f $(docker ps -aq) 2>/dev/null || true
    fi

    print_info "卸载 Docker..."
    apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true

    rm -f /etc/apt/sources.list.d/docker.list
    rm -f /etc/apt/keyrings/docker.gpg
    rm -f /etc/docker/daemon.json

    rm -rf /var/lib/docker
    rm -rf /var/lib/containerd

    print_success "✅ Docker 已完全卸载"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_docker
fi
