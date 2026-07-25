#!/bin/bash

set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"

cleanup() {
    rm -rf "$TEST_ROOT"
}

trap cleanup EXIT

write_os_release() {
    local name="$1"
    local content="$2"

    printf '%s\n' "$content" > "$TEST_ROOT/$name"
}

assert_supported() {
    local fixture="$1"
    local description="$2"

    if SERVER_CAT_OS_RELEASE_FILE="$TEST_ROOT/$fixture" \
        bash -c 'source "$1/lib/platform.sh"; server_cat_platform_is_supported' _ "$PROJECT_ROOT"; then
        printf 'PASS %s\n' "$description"
    else
        printf 'FAIL %s\n' "$description" >&2
        return 1
    fi
}

assert_unsupported() {
    local fixture="$1"
    local description="$2"

    if SERVER_CAT_OS_RELEASE_FILE="$TEST_ROOT/$fixture" \
        bash -c 'source "$1/lib/platform.sh"; server_cat_platform_is_supported' _ "$PROJECT_ROOT"; then
        printf 'FAIL %s\n' "$description" >&2
        return 1
    fi

    printf 'PASS %s\n' "$description"
}

write_os_release ubuntu-2404 $'ID=ubuntu\nVERSION_ID="24.04"'
write_os_release ubuntu-2204 $'ID=ubuntu\nVERSION_ID="22.04"'
write_os_release debian-12 $'ID=debian\nVERSION_ID="12"'
write_os_release debian-11 $'ID=debian\nVERSION_ID="11"'
write_os_release rocky-9 $'ID="rocky"\nVERSION_ID="9.5"'

assert_supported ubuntu-2404 "Ubuntu 24.04 被识别为受支持系统"
assert_supported ubuntu-2204 "Ubuntu 22.04 被识别为受支持系统"
assert_supported debian-12 "Debian 12 被识别为受支持系统"
assert_supported debian-11 "Debian 11 被识别为受支持系统"
assert_unsupported rocky-9 "未验证的 Rocky Linux 不会被误判为受支持系统"
