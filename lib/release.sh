#!/bin/bash

# 签名发布源的只读检查逻辑。该文件会被 main.sh source，不能在顶层修改 shell 错误处理。

SERVER_CAT_RELEASE_BASE_URL_DEFAULT="https://packages.catbuli.com/server-cat"
SERVER_CAT_RELEASE_KEYRING_DEFAULT="/etc/server-cat/release-keyring.gpg"
SERVER_CAT_INSTALL_ROOT_DEFAULT="/opt/server-cat"

server_cat_release_base_url() {
    printf '%s\n' "${SERVER_CAT_RELEASE_BASE_URL:-$SERVER_CAT_RELEASE_BASE_URL_DEFAULT}"
}

server_cat_release_keyring() {
    printf '%s\n' "${SERVER_CAT_RELEASE_KEYRING:-$SERVER_CAT_RELEASE_KEYRING_DEFAULT}"
}

server_cat_install_root() {
    printf '%s\n' "${SERVER_CAT_INSTALL_ROOT:-$SERVER_CAT_INSTALL_ROOT_DEFAULT}"
}

server_cat_release_platform() {
    case "$(uname -m)" in
        x86_64) printf '%s\n' "linux-amd64" ;;
        aarch64|arm64) printf '%s\n' "linux-arm64" ;;
        *) return 1 ;;
    esac
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
    local base_url keyring install_root temporary_dir platform
    local channel_file channel_signature manifest_file manifest_signature
    local channel_data version manifest_path artifact_url artifact_sha256 artifact_size
    local archive_path staging_dir release_dir current_link old_target

    base_url=$(server_cat_release_base_url)
    keyring=$(server_cat_release_keyring)
    install_root=$(server_cat_install_root)

    [[ "$base_url" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._/-]+)?$ ]] || {
        print_error "发布源地址无效"
        return 1
    }
    [[ -r "$keyring" ]] || {
        print_error "未找到发布公钥: $keyring"
        return 1
    }
    server_cat_release_require_tools || return 1
    for command_name in sha256sum tar zstd; do
        command -v "$command_name" > /dev/null 2>&1 || {
            print_error "缺少更新安装依赖: $command_name"
            return 1
        }
    done
    platform=$(server_cat_release_platform) || {
        print_error "暂不支持当前 CPU 架构: $(uname -m)"
        return 1
    }
    if ! temporary_dir=$(mktemp -d); then
        print_error "无法创建临时目录"
        return 1
    fi

    channel_file="$temporary_dir/stable.json"
    channel_signature="$temporary_dir/stable.json.asc"
    manifest_file="$temporary_dir/manifest.json"
    manifest_signature="$temporary_dir/manifest.json.asc"
    archive_path="$temporary_dir/server-cat.tar.zst"

    print_step "下载并验证更新清单..."
    if ! server_cat_release_download "$base_url/channels/stable.json" "$channel_file" ||
        ! server_cat_release_download "$base_url/channels/stable.json.asc" "$channel_signature" ||
        ! server_cat_release_verify "$keyring" "$channel_signature" "$channel_file"; then
        print_error "渠道清单下载或验签失败"
        rm -rf "$temporary_dir"
        return 1
    fi
    channel_data=$(server_cat_release_read_channel "$channel_file") || {
        rm -rf "$temporary_dir"
        return 1
    }
    IFS=$'\t' read -r version manifest_path <<< "$channel_data"
    if ! server_cat_release_download "$base_url/$manifest_path" "$manifest_file" ||
        ! server_cat_release_download "$base_url/$manifest_path.asc" "$manifest_signature" ||
        ! server_cat_release_verify "$keyring" "$manifest_signature" "$manifest_file"; then
        print_error "版本清单下载或验签失败"
        rm -rf "$temporary_dir"
        return 1
    fi
    if ! jq -e --arg version "$version" --arg platform "$platform" '
        .schema_version == 1 and .version == $version and
        (.artifacts[$platform].url | type == "string") and
        (.artifacts[$platform].sha256 | test("^[0-9a-f]{64}$")) and
        (.artifacts[$platform].size | type == "number" and . > 0)
    ' "$manifest_file" > /dev/null; then
        print_error "版本清单缺少当前架构的有效发布包"
        rm -rf "$temporary_dir"
        return 1
    fi
    artifact_url=$(jq -r --arg platform "$platform" '.artifacts[$platform].url' "$manifest_file")
    artifact_sha256=$(jq -r --arg platform "$platform" '.artifacts[$platform].sha256' "$manifest_file")
    artifact_size=$(jq -r --arg platform "$platform" '.artifacts[$platform].size' "$manifest_file")
    if ! server_cat_is_safe_release_path "$artifact_url"; then
        print_error "发布包路径无效"
        rm -rf "$temporary_dir"
        return 1
    fi

    print_step "下载发布包 $version..."
    if ! server_cat_release_download "$base_url/$artifact_url" "$archive_path"; then
        print_error "下载发布包失败"
        rm -rf "$temporary_dir"
        return 1
    fi
    if [[ "$(wc -c < "$archive_path")" != "$artifact_size" ]] ||
        [[ "$(sha256sum "$archive_path" | awk '{print $1}')" != "$artifact_sha256" ]]; then
        print_error "发布包大小或 SHA-256 校验失败"
        rm -rf "$temporary_dir"
        return 1
    fi
    if zstd --decompress --stdout "$archive_path" | tar -tf - | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
        print_error "发布包包含不安全路径"
        rm -rf "$temporary_dir"
        return 1
    fi

    mkdir -p "$install_root/releases"
    release_dir="$install_root/releases/$version"
    if [[ -d "$release_dir" ]]; then
        print_info "版本已存在，切换到已验证版本: $version"
    else
        staging_dir="$install_root/releases/.${version}.staging.$$"
        mkdir -p "$staging_dir"
        if ! zstd --decompress --stdout "$archive_path" | tar -xf - -C "$staging_dir" ||
            [[ ! -x "$staging_dir/server-cat/main.sh" ]] ||
            [[ ! -x "$staging_dir/server-cat/server-cat-agent" ]]; then
            print_error "解压后的发布包结构无效"
            rm -rf "$staging_dir" "$temporary_dir"
            return 1
        fi
        mv "$staging_dir/server-cat" "$release_dir"
        rmdir "$staging_dir"
    fi

    current_link="$install_root/current"
    old_target=$(readlink "$current_link" 2>/dev/null || true)
    ln -s "releases/$version" "$install_root/.current.new"
    mv -Tf "$install_root/.current.new" "$current_link"
    install -d -m 0755 /usr/local/sbin /etc/server-cat
    for command_name in scat server-cat; do
        cat > "/usr/local/sbin/$command_name" <<'EOF'
#!/bin/bash
exec /opt/server-cat/current/main.sh "$@"
EOF
        chmod 0755 "/usr/local/sbin/$command_name"
    done
    if ! dpkg -s bash-completion > /dev/null 2>&1; then
        print_step "安装 Bash Tab 补全支持..."
        if ! apt-get update || ! apt-get install -y bash-completion; then
            print_warning "无法安装 bash-completion，已跳过 Tab 补全安装"
        fi
    fi
    if dpkg -s bash-completion > /dev/null 2>&1; then
        install -d -m 0755 /usr/share/bash-completion/completions
        install -m 0644 \
            "$release_dir/completions/scat.bash" \
            /usr/share/bash-completion/completions/scat
    fi
    if [[ ! -f /etc/server-cat/agent.toml ]]; then
        install -m 0644 "$release_dir/configs/agent.toml.example" /etc/server-cat/agent.toml
    fi
    if [[ ! -f /etc/server-cat/smtp.env ]]; then
        install -m 0600 "$release_dir/configs/smtp.env.example" /etc/server-cat/smtp.env
    fi
    install -m 0644 "$release_dir/systemd/server-cat-agent.service" /etc/systemd/system/server-cat-agent.service
    install -m 0644 "$release_dir/systemd/server-cat-agent.timer" /etc/systemd/system/server-cat-agent.timer
    systemctl daemon-reload
    if ! "$release_dir/server-cat-agent" validate-config --config /etc/server-cat/agent.toml; then
        print_error "新版本配置校验失败，正在恢复旧版本"
        if [[ -n "$old_target" ]]; then
            ln -s "$old_target" "$install_root/.current.rollback"
            mv -Tf "$install_root/.current.rollback" "$current_link"
        fi
        rm -rf "$temporary_dir"
        return 1
    fi
    rm -rf "$temporary_dir"
    print_success "已切换到 Server Cat $version"
    if dpkg -s bash-completion > /dev/null 2>&1; then
        print_info "重新打开 Bash 或执行 source /usr/share/bash-completion/completions/scat 后可使用 Tab 补全"
    fi
    return 0
}

server_cat_update_rollback() {
    local version="$1"
    local install_root release_dir

    server_cat_is_valid_version "$version" || {
        print_error "回退版本号无效"
        return 1
    }
    install_root=$(server_cat_install_root)
    release_dir="$install_root/releases/$version"
    [[ -x "$release_dir/main.sh" && -x "$release_dir/server-cat-agent" ]] || {
        print_error "未找到已安装版本: $version"
        return 1
    }
    ln -s "releases/$version" "$install_root/.current.rollback"
    mv -Tf "$install_root/.current.rollback" "$install_root/current"
    systemctl daemon-reload
    print_success "已回退到 Server Cat $version"
    return 0
}
