#!/bin/bash

set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "用法: $0 <版本> <平台> <Agent 二进制路径> <输出目录>" >&2
    exit 1
fi

VERSION="$1"
PLATFORM="$2"
AGENT_BINARY="$3"
OUTPUT_DIR="$4"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
    echo "版本号无效: $VERSION" >&2
    exit 1
fi

if [[ ! "$PLATFORM" =~ ^[a-z0-9]+-[a-z0-9]+$ ]]; then
    echo "平台标识无效: $PLATFORM" >&2
    exit 1
fi

if [[ ! -x "$AGENT_BINARY" ]]; then
    echo "Agent 二进制不存在或不可执行: $AGENT_BINARY" >&2
    exit 1
fi

for command_name in tar zstd; do
    command -v "$command_name" > /dev/null 2>&1 || {
        echo "缺少命令: $command_name" >&2
        exit 1
    }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STAGING_DIR="$(mktemp -d)"
PACKAGE_ROOT="$STAGING_DIR/server-cat"
ARCHIVE_NAME="server-cat-$PLATFORM.tar.zst"

cleanup() {
    rm -rf "$STAGING_DIR"
}

trap cleanup EXIT

mkdir -p "$PACKAGE_ROOT/completions" "$PACKAGE_ROOT/systemd" "$OUTPUT_DIR"

for path in main.sh lib configs templates backups modules softwares scripts; do
    cp -a "$PROJECT_ROOT/$path" "$PACKAGE_ROOT/$path"
done

rm -f \
    "$PACKAGE_ROOT/scripts/build-release.sh" \
    "$PACKAGE_ROOT/scripts/create-release-manifest.sh"
find "$PACKAGE_ROOT" -name '.DS_Store' -type f -delete

install -m 0755 "$AGENT_BINARY" "$PACKAGE_ROOT/server-cat-agent"
install -m 0644 \
    "$PROJECT_ROOT/packaging/completions/scat.bash" \
    "$PACKAGE_ROOT/completions/scat.bash"
install -m 0644 \
    "$PROJECT_ROOT/packaging/systemd/server-cat-agent.service" \
    "$PACKAGE_ROOT/systemd/server-cat-agent.service"
install -m 0644 \
    "$PROJECT_ROOT/packaging/systemd/server-cat-agent.timer" \
    "$PACKAGE_ROOT/systemd/server-cat-agent.timer"
printf '%s\n' "$VERSION" > "$PACKAGE_ROOT/VERSION"

find "$PACKAGE_ROOT" -type f -name '*.sh' -exec chmod 0755 {} +
tar -C "$STAGING_DIR" -cf - server-cat | zstd -19 --stdout > "$OUTPUT_DIR/$ARCHIVE_NAME"

printf '%s\n' "$OUTPUT_DIR/$ARCHIVE_NAME"
