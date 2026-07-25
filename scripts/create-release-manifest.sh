#!/bin/bash

set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "用法: $0 <版本> <平台> <发布包路径> <输出文件>" >&2
    exit 1
fi

VERSION="$1"
PLATFORM="$2"
ARTIFACT_PATH="$3"
OUTPUT_FILE="$4"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
    echo "版本号无效: $VERSION" >&2
    exit 1
fi

if [[ ! "$PLATFORM" =~ ^[a-z0-9]+-[a-z0-9]+$ ]]; then
    echo "平台标识无效: $PLATFORM" >&2
    exit 1
fi

if [[ ! -f "$ARTIFACT_PATH" ]]; then
    echo "发布包不存在: $ARTIFACT_PATH" >&2
    exit 1
fi

for command_name in jq sha256sum stat; do
    command -v "$command_name" > /dev/null 2>&1 || {
        echo "缺少命令: $command_name" >&2
        exit 1
    }
done

ARTIFACT_NAME="$(basename "$ARTIFACT_PATH")"
SHA256="$(sha256sum "$ARTIFACT_PATH" | awk '{print $1}')"
if SIZE="$(stat --format='%s' "$ARTIFACT_PATH" 2>/dev/null)"; then
    :
else
    SIZE="$(stat -f '%z' "$ARTIFACT_PATH")"
fi

jq -n \
    --arg version "$VERSION" \
    --arg published_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg platform "$PLATFORM" \
    --arg url "releases/$VERSION/$ARTIFACT_NAME" \
    --arg sha256 "$SHA256" \
    --argjson size "$SIZE" \
    '{
        schema_version: 1,
        version: $version,
        published_at: $published_at,
        supported_operating_systems: ["ubuntu", "debian"],
        artifacts: {
            ($platform): {
                url: $url,
                sha256: $sha256,
                size: $size
            }
        },
        release_notes: "请在 GitHub Release 查看完整更新说明"
    }' > "$OUTPUT_FILE"
