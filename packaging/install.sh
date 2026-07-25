#!/bin/bash

set -euo pipefail

BASE_URL="${SERVER_CAT_RELEASE_BASE_URL:-https://packages.catbuli.com/server-cat}"
INSTALL_ROOT="/opt/server-cat"
KEYRING="/etc/server-cat/release-keyring.gpg"

[[ $EUID -eq 0 ]] || {
    echo "请使用 sudo 运行安装脚本" >&2
    exit 1
}

os_release_value() {
    local key="$1"
    local value

    [[ -r /etc/os-release ]] || return 1
    value=$(sed -n "s/^${key}=//p" /etc/os-release | head -n 1)
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"
    printf '%s\n' "$value"
}

require_supported_system() {
    local os_id
    local os_version

    os_id=$(os_release_value ID 2>/dev/null || true)
    os_version=$(os_release_value VERSION_ID 2>/dev/null || true)

    case "$os_id" in
        ubuntu|debian)
            ;;
        *)
            echo "不支持的系统: ${os_id:-未知} ${os_version:-未知}" >&2
            echo "当前支持使用 apt 和 systemd 的 Ubuntu、Debian 系统。" >&2
            exit 1
            ;;
    esac

    command -v systemctl > /dev/null 2>&1 || {
        echo "当前系统未提供 systemctl，无法安装 Server Cat Agent" >&2
        exit 1
    }
    command -v apt-get > /dev/null 2>&1 || {
        echo "当前系统未提供 apt-get，无法安装所需依赖" >&2
        exit 1
    }

    printf '安装环境: %s %s\n' "$os_id" "$os_version"
}

require_supported_system

case "$(uname -m)" in
    x86_64) platform="linux-amd64" ;;
    aarch64|arm64) platform="linux-arm64" ;;
    *) echo "不支持的 CPU 架构: $(uname -m)" >&2; exit 1 ;;
esac

missing_dependencies=()
for command_name in curl gpgv jq sha256sum tar zstd; do
    command -v "$command_name" > /dev/null 2>&1 || missing_dependencies+=("$command_name")
done

if [[ ${#missing_dependencies[@]} -gt 0 ]]; then
    printf '安装首次运行依赖: %s\n' "${missing_dependencies[*]}"
    apt-get update
    apt-get install -y curl gnupg jq coreutils tar zstd
fi

temporary_dir="$(mktemp -d)"
cleanup() {
    rm -rf "$temporary_dir"
}
trap cleanup EXIT

curl --fail --silent --show-error --location --proto '=https' \
    --output "$temporary_dir/keyring.gpg" \
    "$BASE_URL/keys/server-cat-release-keyring.gpg"
curl --fail --silent --show-error --location --proto '=https' \
    --output "$temporary_dir/stable.json" \
    "$BASE_URL/channels/stable.json"

version="$(jq -r '.version' "$temporary_dir/stable.json")"
manifest="$(jq -r '.manifest' "$temporary_dir/stable.json")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] ||
    [[ ! "$manifest" =~ ^[A-Za-z0-9._/-]+$ || "$manifest" == *".."* ]]; then
    echo "stable 渠道清单格式无效" >&2
    exit 1
fi

curl --fail --silent --show-error --location --proto '=https' \
    --output "$temporary_dir/manifest.json" \
    "$BASE_URL/$manifest"
artifact="$(jq -r --arg platform "$platform" '.artifacts[$platform].url' "$temporary_dir/manifest.json")"
expected_sha256="$(jq -r --arg platform "$platform" '.artifacts[$platform].sha256' "$temporary_dir/manifest.json")"
expected_size="$(jq -r --arg platform "$platform" '.artifacts[$platform].size' "$temporary_dir/manifest.json")"
if [[ ! "$artifact" =~ ^[A-Za-z0-9._/-]+$ || "$artifact" == *".."* ]] ||
    [[ ! "$expected_sha256" =~ ^[0-9a-f]{64}$ || ! "$expected_size" =~ ^[0-9]+$ ]]; then
    echo "发布源没有适用于 $platform 的有效安装包" >&2
    exit 1
fi

curl --fail --silent --show-error --location --proto '=https' \
    --output "$temporary_dir/server-cat.tar.zst" \
    "$BASE_URL/$artifact"
[[ "$(wc -c < "$temporary_dir/server-cat.tar.zst")" == "$expected_size" ]]
[[ "$(sha256sum "$temporary_dir/server-cat.tar.zst" | awk '{print $1}')" == "$expected_sha256" ]]
! zstd --decompress --stdout "$temporary_dir/server-cat.tar.zst" | tar -tf - | grep -Eq '(^/|(^|/)\.\.(/|$))'

mkdir -p "$INSTALL_ROOT/releases" /etc/server-cat /usr/local/sbin
staging_dir="$INSTALL_ROOT/releases/.${version}.staging.$$"
mkdir -p "$staging_dir"
zstd --decompress --stdout "$temporary_dir/server-cat.tar.zst" | tar -xf - -C "$staging_dir"
[[ -x "$staging_dir/server-cat/main.sh" && -x "$staging_dir/server-cat/server-cat-agent" ]]
mv "$staging_dir/server-cat" "$INSTALL_ROOT/releases/$version"
rmdir "$staging_dir"
ln -s "releases/$version" "$INSTALL_ROOT/.current.new"
mv -Tf "$INSTALL_ROOT/.current.new" "$INSTALL_ROOT/current"
install -m 0644 "$temporary_dir/keyring.gpg" "$KEYRING"
if [[ -f /etc/server-cat/agent.toml ]]; then
    printf '保留已有配置: /etc/server-cat/agent.toml\n'
else
    install -m 0644 "$INSTALL_ROOT/current/configs/agent.toml.example" /etc/server-cat/agent.toml
    printf '已创建默认配置: /etc/server-cat/agent.toml\n'
fi
if [[ ! -f /etc/server-cat/smtp.env ]]; then
    install -m 0600 "$INSTALL_ROOT/current/configs/smtp.env.example" /etc/server-cat/smtp.env
    printf '已创建 SMTP 配置模板: /etc/server-cat/smtp.env\n'
fi
install -m 0644 "$INSTALL_ROOT/current/systemd/server-cat-agent.service" /etc/systemd/system/server-cat-agent.service
install -m 0644 "$INSTALL_ROOT/current/systemd/server-cat-agent.timer" /etc/systemd/system/server-cat-agent.timer
for command_name in scat server-cat; do
    cat > "/usr/local/sbin/$command_name" <<'EOF'
#!/bin/bash
exec /opt/server-cat/current/main.sh "$@"
EOF
    chmod 0755 "/usr/local/sbin/$command_name"
done
systemctl daemon-reload
"$INSTALL_ROOT/current/server-cat-agent" validate-config --config /etc/server-cat/agent.toml
printf '配置文件格式和阈值校验通过: /etc/server-cat/agent.toml\n'
printf 'Server Cat %s 安装完成。\n' "$version"
