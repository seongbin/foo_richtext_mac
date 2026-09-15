#!/usr/bin/env bash
set -euo pipefail

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
NC=$'\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPONENT_NAME="foo_richtext_mac"
COMPONENT_EXT=".fb2k-component"

cd "$PROJECT_DIR"

SDK_DIR="${PROJECT_DIR}/sdk"
SRC_DIR="${PROJECT_DIR}/src"
BUILD_LOG="$(mktemp -t foo_richtext_mac-build.XXXXXX)"
trap 'rm -f "$BUILD_LOG"' EXIT

build_sdk_target() {
    local project="$1"
    local target="$2"
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild -project "$project" -target "$target" -configuration Release \
        -arch arm64 CONFIGURATION_BUILD_DIR="$SDK_DIR" build >>"$BUILD_LOG" 2>&1
}

build_sdk_target "${SDK_DIR}/pfc/pfc.xcodeproj" pfc
build_sdk_target "${SDK_DIR}/foobar2000/SDK/foobar2000_SDK.xcodeproj" foobar2000_SDK
build_sdk_target "${SDK_DIR}/foobar2000/helpers/foobar2000_SDK_helpers.xcodeproj" foobar2000_SDK_helpers
build_sdk_target "${SDK_DIR}/foobar2000/shared/shared.xcodeproj" shared
build_sdk_target "${SDK_DIR}/foobar2000/foobar2000_component_client/foobar2000_component_client.xcodeproj" foobar2000_component_client

printf "${YELLOW}Building...\r${NC}"
if DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDK="${SDK_DIR}" \
    xcodebuild -project "${SRC_DIR}/foo_richtext_mac.xcodeproj" -scheme foo_richtext_mac \
    -configuration Release -arch arm64 build >>"$BUILD_LOG" 2>&1; then
    printf "${GREEN}BUILD SUCCEEDED${NC}  \n"
else
    printf "${RED}BUILD FAILED${NC}    \n"
    grep -E "error:" "$BUILD_LOG" || tail -40 "$BUILD_LOG"
    exit 1
fi

BUILT=$(find ~/Library/Developer/Xcode/DerivedData/foo_richtext_mac-*/Build/Products/Release -name "${COMPONENT_NAME}.component" -type d -print -quit 2>/dev/null)
if [[ -z "$BUILT" || ! -d "$BUILT" ]]; then
    printf "${RED}EXPORT FAILED${NC}  \n"
    exit 1
fi

DEST_DIST="${PROJECT_DIR}/dist/${COMPONENT_NAME}${COMPONENT_EXT}"
DEST_FOOBAR_DIR="${HOME}/Library/foobar2000-v2/user-components/${COMPONENT_NAME}"
DEST_FOOBAR="${DEST_FOOBAR_DIR}/${COMPONENT_NAME}.component"

mkdir -p "${PROJECT_DIR}/dist" "$DEST_FOOBAR_DIR"
rm -rf "$DEST_DIST" "$DEST_FOOBAR"
ditto "$BUILT" "$DEST_FOOBAR"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$TEMP_DIR/mac"
cp -R "$BUILT" "$TEMP_DIR/mac/"
(
    cd "$TEMP_DIR"
    zip -qr "$DEST_DIST" mac/
)
printf "${GREEN}EXPORTED${NC}  dist/ and foobar2000/user-components/${COMPONENT_NAME}/\n"
