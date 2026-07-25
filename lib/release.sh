#!/bin/bash

# 签名发布源的只读检查逻辑。该文件会被 main.sh source，不能在顶层修改 shell 错误处理。

SERVER_CAT_RELEASE_BASE_URL_DEFAULT="https://packages.catbuli.com/server-cat"
SERVER_CAT_RELEASE_KEYRING_DEFAULT="/etc/server-cat/release-keyring.gpg"

server_cat_release_base_url() {
    printf '%s\n' "${SERVER_CAT_RELEASE_BASE_URL:-$SERVER_CAT_RELEASE_BASE_URL_DEFAULT}"
}

server_cat_release_keyring() {
    printf '%s\n' "${SERVER_CAT_RELEASE_KEYRING:-$SERVER_CAT_RELEASE_KEYRING_DEFAULT}"
}

server_cat_is_safe_release_path() {
    local path="$1"

    [[ -n "$path" ]] || return 1
    [[ "$path" != /* ]] || return 1
    [[ "$path" != *"://"* ]] || return 1
    [[ "$path" != *".."* ]] || return 1
    [[ "$path" =~ ^[A-Za-z0-9._/-]+$ ]]
}

server_cat_is_valid_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]
}

server_cat_release_require_tools() {
    local command_name

    for command_name in curl gpgv jq; do
        if ! command -v "$command_name" > /dev/null 2>&1; then
            print_error "缺少更新检查依赖: $command_name"
            return 1
        fi
    done

    return 0
}

server_cat_release_download() {
    local url="$1"
    local output="$2"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --proto '=https' \
        --tlsv1.2 \
        --output "$output" \
        "$url"
}

server_cat_release_verify() {
    local keyring="$1"
    local signature="$2"
    local document="$3"

    gpgv --keyring "$keyring" "$signature" "$document" > /dev/null 2>&1
}

server_cat_release_read_channel() {
    local channel_file="$1"
    local version
    local manifest

    if ! jq -e '
        type == "object" and
        .schema_version == 1 and
        .channel == "stable" and
        (.version | type == "string") and
        (.manifest | type == "string")
    ' "$channel_file" > /dev/null; then
        print_error "渠道清单格式无效"
        return 1
    fi

    version=$(jq -r '.version' "$channel_file")
    manifest=$(jq -r '.manifest' "$channel_file")

    if ! server_cat_is_valid_version "$version"; then
        print_error "渠道清单中的版本号无效"
        return 1
    fi

    if ! server_cat_is_safe_release_path "$manifest"; then
        print_error "渠道清单中的版本清单路径无效"
        return 1
    fi

    printf '%s\t%s\n' "$version" "$manifest"
}

server_cat_release_read_manifest() {
    local manifest_file="$1"
    local expected_version="$2"

    if ! jq -e --arg version "$expected_version" '
        type == "object" and
        .schema_version == 1 and
        .version == $version and
        (.artifacts | type == "object" and length > 0)
    ' "$manifest_file" > /dev/null; then
        print_error "版本清单格式无效"
        return 1
    fi

    printf '%s\n' "$(jq -r '.published_at // "未知"' "$manifest_file")"
}

server_cat_update_check() {
    local base_url
    local keyring
    local temporary_dir
    local channel_file
    local channel_signature
    local manifest_file
    local manifest_signature
    local channel_data
    local version
    local manifest_path
    local published_at

    base_url=$(server_cat_release_base_url)
    keyring=$(server_cat_release_keyring)

    if [[ ! "$base_url" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._/-]+)?$ ]]; then
        print_error "发布源地址无效"
        return 1
    fi

    if [[ ! -r "$keyring" ]]; then
        print_error "未找到发布公钥: $keyring"
        return 1
    fi

    server_cat_release_require_tools || return 1

    if ! temporary_dir=$(mktemp -d); then
        print_error "无法创建临时目录"
        return 1
    fi

    channel_file="$temporary_dir/stable.json"
    channel_signature="$temporary_dir/stable.json.asc"
    manifest_file="$temporary_dir/manifest.json"
    manifest_signature="$temporary_dir/manifest.json.asc"

    print_step "检查 Server Cat 更新..."

    if ! server_cat_release_download "$base_url/channels/stable.json" "$channel_file" ||
        ! server_cat_release_download "$base_url/channels/stable.json.asc" "$channel_signature"; then
        print_error "下载渠道清单失败"
        rm -rf "$temporary_dir"
        return 1
    fi

    if ! server_cat_release_verify "$keyring" "$channel_signature" "$channel_file"; then
        print_error "渠道清单签名验证失败"
        rm -rf "$temporary_dir"
        return 1
    fi

    if ! channel_data=$(server_cat_release_read_channel "$channel_file"); then
        rm -rf "$temporary_dir"
        return 1
    fi

    IFS=$'\t' read -r version manifest_path <<< "$channel_data"

    if ! server_cat_release_download "$base_url/$manifest_path" "$manifest_file" ||
        ! server_cat_release_download "$base_url/$manifest_path.asc" "$manifest_signature"; then
        print_error "下载版本清单失败"
        rm -rf "$temporary_dir"
        return 1
    fi

    if ! server_cat_release_verify "$keyring" "$manifest_signature" "$manifest_file"; then
        print_error "版本清单签名验证失败"
        rm -rf "$temporary_dir"
        return 1
    fi

    if ! published_at=$(server_cat_release_read_manifest "$manifest_file" "$version"); then
        rm -rf "$temporary_dir"
        return 1
    fi

    print_success "已验证 stable 通道版本: $version"
    print_info "发布时间: $published_at"
    rm -rf "$temporary_dir"
    return 0
}

server_cat_update_apply() {
    print_warning "签名更新安装器尚未发布，当前只能执行 update check"
    return 1
}

server_cat_update_rollback() {
    print_warning "签名更新安装器尚未发布，当前不能回退版本"
    return 1
}
