#!/bin/bash

set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
FIXTURE_DIR="$TEST_ROOT/fixtures"
MOCK_BIN="$TEST_ROOT/bin"

cleanup() {
    rm -rf "$TEST_ROOT"
}

trap cleanup EXIT

mkdir -p "$FIXTURE_DIR" "$MOCK_BIN"
touch "$TEST_ROOT/release-keyring.gpg"

printf '%s\n' \
    '{"schema_version":1,"channel":"stable","version":"0.1.0","manifest":"releases/0.1.0/manifest.json"}' \
    > "$FIXTURE_DIR/stable.json"
printf '%s\n' 'signature' > "$FIXTURE_DIR/stable.json.asc"
printf '%s\n' \
    '{"schema_version":1,"version":"0.1.0","published_at":"2026-07-25T12:00:00Z","artifacts":{"linux-amd64":{"url":"releases/0.1.0/server-cat-linux-amd64.tar.zst","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":1}}}' \
    > "$FIXTURE_DIR/manifest.json"
printf '%s\n' 'signature' > "$FIXTURE_DIR/manifest.json.asc"

cat > "$MOCK_BIN/curl" <<'EOF'
#!/bin/bash

set -u

output=""
url=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            output="$2"
            shift 2
            ;;
        *)
            url="$1"
            shift
            ;;
    esac
done

case "$url" in
    */channels/stable.json)
        cp "$SERVER_CAT_TEST_FIXTURE_DIR/stable.json" "$output"
        ;;
    */channels/stable.json.asc)
        cp "$SERVER_CAT_TEST_FIXTURE_DIR/stable.json.asc" "$output"
        ;;
    */releases/0.1.0/manifest.json)
        cp "$SERVER_CAT_TEST_FIXTURE_DIR/manifest.json" "$output"
        ;;
    */releases/0.1.0/manifest.json.asc)
        cp "$SERVER_CAT_TEST_FIXTURE_DIR/manifest.json.asc" "$output"
        ;;
    *)
        exit 1
        ;;
esac
EOF

cat > "$MOCK_BIN/gpgv" <<'EOF'
#!/bin/bash

exit 0
EOF

chmod +x "$MOCK_BIN/curl" "$MOCK_BIN/gpgv"

run_update_check() {
    PATH="$MOCK_BIN:$PATH" \
        SERVER_CAT_TEST_FIXTURE_DIR="$FIXTURE_DIR" \
        SERVER_CAT_RELEASE_BASE_URL="https://packages.example.test/server-cat" \
        SERVER_CAT_RELEASE_KEYRING="$TEST_ROOT/release-keyring.gpg" \
        bash -c 'source "$1/lib/utils.sh"; source "$1/lib/release.sh"; server_cat_update_check' _ "$PROJECT_ROOT"
}

if ! run_update_check > /dev/null; then
    printf 'FAIL 有效且已签名的发布清单应通过更新检查\n' >&2
    exit 1
fi

printf '%s\n' \
    '{"schema_version":1,"channel":"stable","version":"0.1.0","manifest":"../outside.json"}' \
    > "$FIXTURE_DIR/stable.json"

if run_update_check > /dev/null 2>&1; then
    printf 'FAIL 渠道清单不能引用发布根目录外的路径\n' >&2
    exit 1
fi

printf 'PASS 更新检查接受有效清单并拒绝路径穿越\n'
