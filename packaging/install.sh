#!/bin/bash

set -euo pipefail

BASE_URL="${SERVER_CAT_RELEASE_BASE_URL:-https://packages.catbuli.com/server-cat}"
INSTALL_ROOT="/opt/server-cat"
KEYRING="/etc/server-cat/release-keyring.gpg"

[[ $EUID -eq 0 ]] || {
    echo "请使用 sudo 运行安装脚本" >&2
    exit 1
}

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
    command -v apt-get > /dev/null 2>&1 || {
        echo "缺少依赖且当前系统不支持 apt-get: ${missing_dependencies[*]}" >&2
        exit 1
    }
    apt-get update
    apt-get install -y curl gnupg jq zstd
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
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]
[[ "$manifest" =~ ^[A-Za-z0-9._/-]+$ && "$manifest" != *".."* ]]

curl --fail --silent --show-error --location --proto '=https' \
    --output "$temporary_dir/manifest.json" \
    "$BASE_URL/$manifest"
artifact="$(jq -r --arg platform "$platform" '.artifacts[$platform].url' "$temporary_dir/manifest.json")"
expected_sha256="$(jq -r --arg platform "$platform" '.artifacts[$platform].sha256' "$temporary_dir/manifest.json")"
expected_size="$(jq -r --arg platform "$platform" '.artifacts[$platform].size' "$temporary_dir/manifest.json")"
[[ "$artifact" =~ ^[A-Za-z0-9._/-]+$ && "$artifact" != *".."* ]]
[[ "$expected_sha256" =~ ^[0-9a-f]{64}$ && "$expected_size" =~ ^[0-9]+$ ]]

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
install -m 0644 "$INSTALL_ROOT/current/configs/agent.toml.example" /etc/server-cat/agent.toml
install -m 0644 "$INSTALL_ROOT/current/systemd/server-cat-agent.service" /etc/systemd/system/server-cat-agent.service
install -m 0644 "$INSTALL_ROOT/current/systemd/server-cat-agent.timer" /etc/systemd/system/server-cat-agent.timer
cat > /usr/local/sbin/server-cat <<'EOF'
#!/bin/bash
exec /opt/server-cat/current/main.sh "$@"
EOF
chmod 0755 /usr/local/sbin/server-cat
systemctl daemon-reload
"$INSTALL_ROOT/current/server-cat-agent" validate-config --config /etc/server-cat/agent.toml
printf 'Server Cat %s 安装完成。\n' "$version"
