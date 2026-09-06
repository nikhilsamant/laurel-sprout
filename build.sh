#!/bin/bash
# Wrapper around halium-generic-adaptation-build-tools' build.sh.
# Enabled in CI via ADAPTATION_TOOLS_USE_BUILD_WRAPPER=1.
set -xe
shopt -s extglob

BUILD_DIR=workdir
args=("$@")
for ((i = 0; i < ${#args[@]}; ++i)); do
    case "${args[i]}" in
        -b) BUILD_DIR="${args[i + 1]}"; unset "args[i]" "args[i + 1]"; break ;;
    esac
done

[ -d build ] || git clone https://gitlab.com/ubports/porting/community-ports/halium-generic-adaptation-build-tools build

[ "$ADAPTATION_TOOLS_USE_TMP_BUILD_DIR" ] && BUILD_DIR="$(mktemp -d)"
BUILD_DIR="$(realpath "$BUILD_DIR")"
mkdir -p "$BUILD_DIR"

HERE="$(pwd)"
SCRIPT="$HERE/build"
TMPDOWN="$BUILD_DIR/downloads"
mkdir -p "$TMPDOWN"

# Fetch toolchains + sources up front (build/build.sh re-runs this idempotently).
source deviceinfo
source "$SCRIPT/common_functions.sh"
source "$SCRIPT/setup_repositories.sh" "$TMPDOWN"

if [ -n "$CLANG_PATH" ] && [ -d "$CLANG_PATH/bin" ]; then
    ln -sf ld.lld "$CLANG_PATH/bin/ld"
fi

# -b pins the dir we just populated; drop the env var so build/build.sh does
# not mktemp a second (empty) one.
exec env -u ADAPTATION_TOOLS_USE_TMP_BUILD_DIR "$SCRIPT/build.sh" "${args[@]}" -b "$BUILD_DIR"
