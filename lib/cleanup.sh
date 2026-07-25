#!/bin/bash

# 空间清理功能。依赖调用方已加载 lib/utils.sh。

server_cat_cleanup_show_temp_usage() {
    local path
    local size

    print_step "系统临时文件"
    for path in /tmp /var/tmp; do
        [[ -d "$path" ]] || continue
        size=$(du -sh "$path" 2>/dev/null | awk '{print $1}')
        print_info "$path 当前占用: ${size:-无法统计}"
    done
    print_info "仅按 systemd 的临时文件保留规则清理过期内容"
}

server_cat_cleanup_preview_temp() {
    server_cat_cleanup_show_temp_usage
    if ! command -v systemd-tmpfiles > /dev/null 2>&1; then
        print_error "当前系统未提供 systemd-tmpfiles，无法安全清理临时文件"
        return 1
    fi

    if systemd-tmpfiles --clean --dry-run > /dev/null; then
        print_success "系统临时文件规则检查通过"
    else
        print_error "无法检查系统临时文件规则"
        return 1
    fi

    return 0
}

server_cat_cleanup_temp() {
    server_cat_cleanup_preview_temp || return 1

    if ! confirm "按系统临时文件规则清理过期内容"; then
        print_info "已取消临时文件清理"
        return 0
    fi

    if systemd-tmpfiles --clean; then
        print_success "系统临时文件清理完成"
    else
        print_error "系统临时文件清理失败"
        return 1
    fi
}

server_cat_cleanup_require_docker() {
    if ! command -v docker > /dev/null 2>&1; then
        print_warning "未安装 Docker，已跳过 Docker 清理"
        return 1
    fi

    if ! docker info > /dev/null 2>&1; then
        print_error "无法连接 Docker 服务，请确认 Docker 正在运行"
        return 1
    fi

    return 0
}

server_cat_cleanup_show_docker_usage() {
    print_step "Docker 可清理空间"
    server_cat_cleanup_require_docker || return 1
    docker system df
    print_info "仅提供停止容器、悬空镜像和悬空构建缓存清理，不会清理 Docker 卷"
}

server_cat_cleanup_docker_stopped_containers() {
    server_cat_cleanup_require_docker || return 1
    print_warning "将删除所有已停止的 Docker 容器，不影响运行中的容器或 Docker 卷"
    docker container ls --all --filter status=exited --filter status=created --filter status=dead

    if ! confirm_strong "CLEAN" "确认清理已停止 Docker 容器"; then
        print_info "已取消 Docker 容器清理"
        return 0
    fi

    docker container prune --force
}

server_cat_cleanup_docker_dangling_images() {
    server_cat_cleanup_require_docker || return 1
    print_warning "将删除没有标签且未被容器使用的 Docker 镜像，不影响已命名镜像或 Docker 卷"
    docker image ls --filter dangling=true

    if ! confirm_strong "CLEAN" "确认清理 Docker 悬空镜像"; then
        print_info "已取消 Docker 镜像清理"
        return 0
    fi

    docker image prune --force
}

server_cat_cleanup_docker_build_cache() {
    server_cat_cleanup_require_docker || return 1
    print_warning "将删除未使用的 Docker 构建缓存，不影响 Docker 卷"

    if ! confirm_strong "CLEAN" "确认清理 Docker 构建缓存"; then
        print_info "已取消 Docker 构建缓存清理"
        return 0
    fi

    docker builder prune --force
}

server_cat_cleanup_menu() {
    while true; do
        clear_screen
        echo -e "${BLUE}=====================================${NC}"
        echo -e "${BLUE}    🧹 清理系统空间                 ${NC}"
        echo -e "${BLUE}=====================================${NC}"
        echo "1. 查看临时文件与 Docker 空间占用"
        echo "2. 清理系统临时文件"
        echo "3. 清理 Docker 已停止容器"
        echo "4. 清理 Docker 悬空镜像"
        echo "5. 清理 Docker 构建缓存"
        echo "0. 返回系统设置"
        echo -e "${BLUE}-------------------------------------${NC}"
        print_info "不会清理 Docker 卷、运行中的容器、已命名镜像、业务目录或备份"
        read -p "请输入你的选择 [0-5]: " choice

        case "$choice" in
            1)
                server_cat_cleanup_preview_temp
                server_cat_cleanup_show_docker_usage
                ;;
            2) server_cat_cleanup_temp ;;
            3) server_cat_cleanup_docker_stopped_containers ;;
            4) server_cat_cleanup_docker_dangling_images ;;
            5) server_cat_cleanup_docker_build_cache ;;
            0) break ;;
            *) print_error "无效输入，请重试" ;;
        esac

        print_step "请按 [Enter] 键继续..."
        read
    done

    return 0
}
