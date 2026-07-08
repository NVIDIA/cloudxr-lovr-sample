#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: MIT
#
# =============================================================================
# CloudXR LOVR Build Script for Linux
# =============================================================================
# Quick reference (see README.md for full docs):
#   ./build.sh                       Default Debug build with CloudXR.js setup
#   ./build.sh Release               Release build
#   ./build.sh --without-cloudxrjs   Skip CloudXR.js setup
#   ./build.sh --clean               Wipe build/ outputs (keep cached archives)
#
# Custom LÖVR source (default: pinned commit on github.com/bjornbytes/lovr):
#   ./build.sh --lovr-branch <branch>
#   ./build.sh --lovr-commit <hash>
#   ./build.sh --lovr-repo <url>
#
# Any unrecognized argument is forwarded to `cmake` (e.g. -DLOVR_BUILD_BUNDLE=ON).
# =============================================================================

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
BUILD_TYPE="Debug"
LOVR_REPO="https://github.com/bjornbytes/lovr.git"
LOVR_COMMIT="eb04263fce90170e3f27ae451cba6b9158aa2c67"
LOVR_BRANCH=""
WITH_CLOUDXRJS=1
CMAKE_EXTRA_ARGS=()
CLOUDXR_DIR="build/cloudxr"

# CloudXR Runtime / CloudXR.js versions. The build prefers an archive in
# build/cloudxr/ whose filename matches these versions, falls back to any
# matching archive, and finally downloads this version if none is present.
# Override by exporting CLOUDXR_RUNTIME_VERSION / CLOUDXR_JS_VERSION before
# running this script, or edit the defaults below.
CLOUDXR_RUNTIME_VERSION="${CLOUDXR_RUNTIME_VERSION:-6.2.0}"
CLOUDXR_JS_VERSION="${CLOUDXR_JS_VERSION:-6.2.0}"

DEFAULT_CLOUDXR_RUNTIME_ARCHIVE="CloudXR-${CLOUDXR_RUNTIME_VERSION}-Linux-sdk.tar.gz"
DEFAULT_CLOUDXR_RUNTIME_URL="https://api.ngc.nvidia.com/v2/resources/org/nvidia/cloudxr-runtime/${CLOUDXR_RUNTIME_VERSION}/files?redirect=true&path=${DEFAULT_CLOUDXR_RUNTIME_ARCHIVE}"
DEFAULT_CLOUDXR_JS_ARCHIVE="nvidia-cloudxr-${CLOUDXR_JS_VERSION}.tgz"
DEFAULT_CLOUDXR_JS_URL="https://api.ngc.nvidia.com/v2/resources/org/nvidia/cloudxr-js/${CLOUDXR_JS_VERSION}/files?redirect=true&path=${DEFAULT_CLOUDXR_JS_ARCHIVE}"
CLOUDXR_JS_SAMPLES_REPO="https://github.com/NVIDIA/cloudxr-js-samples.git"
CLOUDXR_JS_SAMPLES_DIR="${CLOUDXR_DIR}/cloudxr-js-samples"
CLOUDXR_JS_SAMPLE_DIR="${CLOUDXR_JS_SAMPLES_DIR}/react"
MIN_NODE_VERSION="20.19.0"
CLOUDXR_SDK_DIR=""
CLOUDXR_SDK_INCLUDE_DIR=""
CLOUDXR_SDK_LIB_DIR=""
CLOUDXR_JS_PACKAGE=""

require_option_value() {
    local option="$1"
    local value="${2-}"

    if [ -z "$value" ] || [[ "$value" == -* ]]; then
        echo -e "${RED}❌ Missing value for ${option}${NC}"
        exit 1
    fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --clean)
            echo -e "${YELLOW}Cleaning build directory (keeping CloudXR archives)...${NC}"
            if [ -d build ]; then
                # Stash cached archives outside build/, wipe build/ in one shot,
                # then restore the archives. Keeps the contract simple and avoids
                # silent partial deletion when the tree contains things like
                # node_modules, .git packs, or files held open by a process.
                CLEAN_STASH="$(mktemp -d -t cxr-clean-stash.XXXXXX)"
                if [ -d build/cloudxr ]; then
                    for pattern in 'CloudXR-*-sdk.tar.gz' 'CloudXR-*-sdk.zip' 'nvidia-cloudxr-*.tgz'; do
                        for f in build/cloudxr/$pattern; do
                            [ -f "$f" ] && mv "$f" "$CLEAN_STASH/"
                        done
                    done
                fi
                rm -rf build
                if [ -n "$(ls -A "$CLEAN_STASH" 2>/dev/null)" ]; then
                    mkdir -p build/cloudxr
                    mv "$CLEAN_STASH"/* build/cloudxr/
                fi
                rmdir "$CLEAN_STASH" 2>/dev/null || true
            fi
            echo -e "${GREEN}✓ Clean complete (CloudXR archives in build/cloudxr/ preserved)${NC}"
            echo -e "${BLUE}  To wipe everything including archives, run: rm -rf build && ./build.sh${NC}"
            exit 0
            ;;
        --lovr-repo)
            require_option_value "$1" "${2-}"
            LOVR_REPO="$2"
            shift 2
            ;;
        --lovr-repo=*)
            LOVR_REPO="${1#*=}"
            require_option_value "--lovr-repo" "$LOVR_REPO"
            shift
            ;;
        --lovr-branch)
            require_option_value "$1" "${2-}"
            LOVR_BRANCH="$2"
            LOVR_COMMIT=""
            shift 2
            ;;
        --lovr-branch=*)
            LOVR_BRANCH="${1#*=}"
            require_option_value "--lovr-branch" "$LOVR_BRANCH"
            LOVR_COMMIT=""
            shift
            ;;
        --lovr-commit)
            require_option_value "$1" "${2-}"
            LOVR_COMMIT="$2"
            LOVR_BRANCH=""
            shift 2
            ;;
        --lovr-commit=*)
            LOVR_COMMIT="${1#*=}"
            require_option_value "--lovr-commit" "$LOVR_COMMIT"
            LOVR_BRANCH=""
            shift
            ;;
        --without-cloudxrjs)
            WITH_CLOUDXRJS=0
            shift
            ;;
        Debug|Release|RelWithDebInfo|MinSizeRel)
            BUILD_TYPE="$1"
            shift
            ;;
        *)
            # Anything we don't recognize is forwarded to cmake (e.g. -DFOO=bar).
            CMAKE_EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}CloudXR LOVR Build Script${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}LOVR Repository: ${LOVR_REPO}${NC}"
if [ -n "${LOVR_BRANCH}" ]; then
    echo -e "${BLUE}LOVR Branch: ${LOVR_BRANCH}${NC}"
elif [ -n "${LOVR_COMMIT}" ]; then
    echo -e "${BLUE}LOVR Commit: ${LOVR_COMMIT}${NC}"
else
    echo -e "${BLUE}LOVR Ref: default branch${NC}"
fi
echo -e "${BLUE}Build Type: ${BUILD_TYPE}${NC}"
if [ "$WITH_CLOUDXRJS" -eq 1 ]; then
    echo -e "${BLUE}CloudXR.js Setup: enabled (pass --without-cloudxrjs to skip)${NC}"
else
    echo -e "${BLUE}CloudXR.js Setup: disabled${NC}"
fi
echo -e "${BLUE}========================================${NC}"

# =============================================================================
# Helper functions
# =============================================================================

download_file() {
    local url="$1"
    local output="$2"
    local label="$3"

    if [ -f "$output" ]; then
        echo -e "${GREEN}✓ Found ${label}: ${output}${NC}"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${RED}❌ curl is required to download ${label}${NC}"
        echo -e "${YELLOW}Download it manually from:${NC}"
        echo -e "  ${url}"
        echo -e "${YELLOW}Save it as:${NC}"
        echo -e "  ${output}"
        return 1
    fi

    mkdir -p "$(dirname "$output")"
    echo -e "${YELLOW}Downloading ${label}...${NC}"
    if ! curl -fL "$url" -o "$output"; then
        echo -e "${RED}❌ Failed to download ${label}${NC}"
        return 1
    fi

    if [ ! -s "$output" ]; then
        echo -e "${RED}❌ Downloaded ${label} is empty: ${output}${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ Downloaded ${label}: ${output}${NC}"
}

download_cloudxr_runtime_sdk() {
    download_file "$DEFAULT_CLOUDXR_RUNTIME_URL" "$CLOUDXR_DIR/$DEFAULT_CLOUDXR_RUNTIME_ARCHIVE" "CloudXR Runtime SDK"
}

install_lovr_build_dependencies() {
    local package_manager=""
    local packages=()
    local missing_packages=()

    if command -v apt-get >/dev/null 2>&1 && command -v dpkg-query >/dev/null 2>&1; then
        package_manager="apt"
        # LÖVR docs list these Debian/Ubuntu packages; curl is needed by this script.
        packages=(make cmake xorg-dev libcurl4-openssl-dev libxcb-glx0-dev libx11-xcb-dev python3-minimal curl)
    elif command -v dnf >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1; then
        package_manager="dnf"
        # LÖVR docs list these Fedora packages; curl is needed by this script.
        packages=(cmake clang libX11-devel libXrandr-devel libXinerama-devel libXcursor-devel libXi-devel libcurl-devel curl)
    else
        echo -e "${YELLOW}Could not detect apt or dnf. Skipping automatic LÖVR dependency install.${NC}"
        echo -e "${YELLOW}See: https://lovr.org/docs/Compiling#linux${NC}"
        return 0
    fi

    if [ "$package_manager" = "apt" ]; then
        for package in "${packages[@]}"; do
            if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"; then
                missing_packages+=("$package")
            fi
        done
    else
        for package in "${packages[@]}"; do
            if ! rpm -q "$package" >/dev/null 2>&1; then
                missing_packages+=("$package")
            fi
        done
    fi

    if [ "${#missing_packages[@]}" -eq 0 ]; then
        echo -e "${GREEN}✓ LÖVR Linux build dependencies are installed${NC}"
        return 0
    fi

    echo -e "${YELLOW}Missing LÖVR Linux build dependencies:${NC} ${missing_packages[*]}"

    if [ ! -t 0 ]; then
        echo -e "${YELLOW}Skipping dependency install because this shell is not interactive.${NC}"
        return 0
    fi

    local answer
    read -r -p "Install missing LÖVR Linux build dependencies now? [y/N] " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Skipping LÖVR dependency install. The build may fail if dependencies are missing.${NC}"
        return 0
    fi

    local sudo_cmd=()
    if [ "$(id -u)" -ne 0 ]; then
        if ! command -v sudo >/dev/null 2>&1; then
            echo -e "${RED}❌ sudo is required to install dependencies automatically${NC}"
            return 1
        fi
        sudo_cmd=(sudo)
    fi

    if [ "$package_manager" = "apt" ]; then
        "${sudo_cmd[@]}" apt-get install -y "${missing_packages[@]}"
    else
        "${sudo_cmd[@]}" dnf install -y "${missing_packages[@]}"
    fi
}

stage_cloudxr_sdk_files() {
    local sdk_dir="$1"

    if [ ! -f "$sdk_dir/include/cxrServiceAPI.h" ]; then
        echo -e "${RED}❌ CloudXR SDK headers not found in: $sdk_dir/include${NC}"
        return 1
    fi

    if [ -z "$(ls -A "$sdk_dir"/*.so* 2>/dev/null)" ]; then
        echo -e "${RED}❌ CloudXR SDK libraries not found in: $sdk_dir${NC}"
        return 1
    fi

    CLOUDXR_SDK_DIR="$sdk_dir"
    CLOUDXR_SDK_INCLUDE_DIR="$sdk_dir/include"
    CLOUDXR_SDK_LIB_DIR="$sdk_dir"
}

find_cloudxr_sdk() {
    local candidate

    for candidate in "$CLOUDXR_DIR"/CloudXR-"$CLOUDXR_RUNTIME_VERSION"-Linux*-sdk; do
        if [ -d "$candidate" ] && stage_cloudxr_sdk_files "$candidate"; then
            return 0
        fi
    done

    for candidate in "$CLOUDXR_DIR"/CloudXR-*-Linux*-sdk; do
        if [ -d "$candidate" ] && stage_cloudxr_sdk_files "$candidate"; then
            return 0
        fi
    done

    return 1
}

extract_cloudxr_sdk() {
    echo -e "${YELLOW}CloudXR SDK not found in build directory. Searching for SDK archive...${NC}"

    local sdk_archive=""
    local candidate
    if [ -f "$CLOUDXR_DIR/$DEFAULT_CLOUDXR_RUNTIME_ARCHIVE" ]; then
        sdk_archive="$CLOUDXR_DIR/$DEFAULT_CLOUDXR_RUNTIME_ARCHIVE"
    else
        for candidate in "$CLOUDXR_DIR"/CloudXR-"$CLOUDXR_RUNTIME_VERSION"-Linux*-sdk.tar.gz; do
            if [ -f "$candidate" ]; then
                sdk_archive="$candidate"
                break
            fi
        done
    fi

    if [ -z "$sdk_archive" ]; then
        for candidate in "$CLOUDXR_DIR"/CloudXR-*-Linux*-sdk.tar.gz; do
            if [ -f "$candidate" ]; then
                sdk_archive="$candidate"
                break
            fi
        done
    fi

    if [ -z "$sdk_archive" ]; then
        echo -e "${YELLOW}CloudXR SDK archive not found locally. Downloading CloudXR Runtime SDK...${NC}"
        if ! download_cloudxr_runtime_sdk; then
            echo -e "${YELLOW}You can also download CloudXR SDK from:${NC}"
            echo -e "   https://catalog.ngc.nvidia.com/orgs/nvidia/collections/cloudxr-sdk"
            echo -e "${YELLOW}Place the CloudXR-*-Linux*-sdk.tar.gz file in build/cloudxr/.${NC}"
            exit 1
        fi
        sdk_archive="$CLOUDXR_DIR/$DEFAULT_CLOUDXR_RUNTIME_ARCHIVE"
    fi

    echo -e "${GREEN}✓ Found SDK archive: ${sdk_archive}${NC}"
    echo -e "${YELLOW}Extracting SDK into ${CLOUDXR_DIR}...${NC}"

    local sdk_basename
    sdk_basename="$(basename "$sdk_archive")"
    local sdk_dir="$CLOUDXR_DIR/${sdk_basename%.tar.gz}"

    # Detect whether the archive has a single top-level directory; if so,
    # strip it during extraction so the layout is sdk_dir/include/... etc.
    local strip_args=()
    local first_top
    first_top="$(tar -tzf "$sdk_archive" 2>/dev/null | awk -F/ 'NR==1 {print $1}')"
    if [ -n "$first_top" ] \
        && tar -tzf "$sdk_archive" 2>/dev/null \
            | awk -F/ -v top="$first_top" '$1 != top { exit 1 }'; then
        strip_args=(--strip-components=1)
    fi

    rm -rf "$sdk_dir"
    mkdir -p "$sdk_dir"
    if ! tar -xzf "$sdk_archive" -C "$sdk_dir" "${strip_args[@]}"; then
        echo -e "${RED}❌ Failed to extract SDK archive${NC}"
        rm -rf "$sdk_dir"
        exit 1
    fi

    if ! stage_cloudxr_sdk_files "$sdk_dir"; then
        exit 1
    fi

    echo -e "${GREEN}✓ CloudXR SDK staged in build directory:${NC}"
    echo -e "  Headers: ${CLOUDXR_SDK_INCLUDE_DIR}"
    echo -e "  Libraries: ${CLOUDXR_SDK_LIB_DIR}"
}

ensure_cloudxr_sdk() {
    if find_cloudxr_sdk; then
        echo -e "${GREEN}✓ Reusing existing CloudXR SDK at: ${CLOUDXR_SDK_DIR}${NC}"
        echo -e "${BLUE}  To switch to a new SDK, place the archive in ${CLOUDXR_DIR}/ then run \`./build.sh --clean && ./build.sh\`.${NC}"
        echo -e "${BLUE}  \`--clean\` wipes the build output but keeps cached archives in ${CLOUDXR_DIR}/.${NC}"
        return 0
    fi
    extract_cloudxr_sdk
}

version_at_least() {
    local version="${1#v}"
    local minimum="$2"
    local v_major=0
    local v_minor=0
    local v_patch=0
    local min_major=0
    local min_minor=0
    local min_patch=0

    IFS=. read -r v_major v_minor v_patch _ <<< "$version"
    IFS=. read -r min_major min_minor min_patch _ <<< "$minimum"
    v_major="${v_major%%[^0-9]*}"
    v_minor="${v_minor%%[^0-9]*}"
    v_patch="${v_patch%%[^0-9]*}"
    min_major="${min_major%%[^0-9]*}"
    min_minor="${min_minor%%[^0-9]*}"
    min_patch="${min_patch%%[^0-9]*}"
    v_major="${v_major:-0}"
    v_minor="${v_minor:-0}"
    v_patch="${v_patch:-0}"
    min_major="${min_major:-0}"
    min_minor="${min_minor:-0}"
    min_patch="${min_patch:-0}"

    if (( v_major > min_major )); then return 0; fi
    if (( v_major < min_major )); then return 1; fi
    if (( v_minor > min_minor )); then return 0; fi
    if (( v_minor < min_minor )); then return 1; fi
    (( v_patch >= min_patch ))
}

load_nvm() {
    if command -v nvm >/dev/null 2>&1; then
        return 0
    fi

    local nvm_script="${NVM_DIR:-$HOME/.nvm}/nvm.sh"
    if [ -s "$nvm_script" ]; then
        # shellcheck disable=SC1090
        . "$nvm_script"
    fi

    command -v nvm >/dev/null 2>&1
}

install_nodejs() {
    if load_nvm; then
        echo -e "${YELLOW}Installing Node.js 20 with nvm...${NC}"
        nvm install 20
        nvm use 20
        nvm alias default 20 >/dev/null 2>&1 || true
        hash -r
        return 0
    fi

    echo -e "${YELLOW}Automatic Node.js install is only supported through nvm in this script.${NC}"
    echo -e "${YELLOW}Install Node.js v${MIN_NODE_VERSION}+ from https://nodejs.org/en/download, then rerun ./build.sh.${NC}"
    return 1
}

prompt_for_node_install() {
    local reason="$1"

    echo -e "${YELLOW}${reason}${NC}"
    echo -e "${YELLOW}CloudXR.js setup requires Node.js v${MIN_NODE_VERSION} or later with npm.${NC}"

    if [ ! -t 0 ]; then
        echo -e "${YELLOW}Skipping CloudXR.js setup because this shell is not interactive.${NC}"
        return 1
    fi

    if ! load_nvm; then
        echo -e "${YELLOW}Install Node.js v${MIN_NODE_VERSION}+ from https://nodejs.org/en/download, then rerun ./build.sh.${NC}"
        return 1
    fi

    local answer
    read -r -p "Install Node.js v${MIN_NODE_VERSION}+ now with nvm? [y/N] " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Skipping CloudXR.js setup.${NC}"
        return 1
    fi

    install_nodejs
}

check_node_version() {
    local attempt
    local reason=""

    for attempt in 1 2; do
        load_nvm || true

        if ! command -v node >/dev/null 2>&1; then
            reason="Node.js was not found."
        else
            local node_version
            node_version="$(node -v | sed 's/^v//')"
            if ! version_at_least "$node_version" "$MIN_NODE_VERSION"; then
                reason="Node.js v${node_version} is installed, but v${MIN_NODE_VERSION} or later is required."
            elif ! command -v npm >/dev/null 2>&1; then
                reason="npm was not found."
            else
                echo -e "${GREEN}✓ Node.js v${node_version} meets CloudXR.js requirement${NC}"
                return 0
            fi
        fi

        if [ "$attempt" -eq 2 ]; then
            echo -e "${YELLOW}${reason}${NC}"
            echo -e "${YELLOW}Node.js install did not make v${MIN_NODE_VERSION}+ available in this shell.${NC}"
            echo -e "${YELLOW}Install Node.js v${MIN_NODE_VERSION}+ from https://nodejs.org/en/download, then rerun ./build.sh.${NC}"
            return 1
        fi

        if ! prompt_for_node_install "$reason"; then
            return 1
        fi
    done
}

ensure_cloudxr_js_package() {
    local candidate

    if [ -f "$CLOUDXR_DIR/$DEFAULT_CLOUDXR_JS_ARCHIVE" ]; then
        CLOUDXR_JS_PACKAGE="$CLOUDXR_DIR/$DEFAULT_CLOUDXR_JS_ARCHIVE"
        echo -e "${GREEN}✓ Found CloudXR.js package: ${CLOUDXR_JS_PACKAGE}${NC}"
        return 0
    fi

    for candidate in "$CLOUDXR_DIR"/nvidia-cloudxr-*.tgz; do
        if [ -f "$candidate" ]; then
            CLOUDXR_JS_PACKAGE="$candidate"
            echo -e "${GREEN}✓ Found CloudXR.js package: ${CLOUDXR_JS_PACKAGE}${NC}"
            return 0
        fi
    done

    if ! download_file "$DEFAULT_CLOUDXR_JS_URL" "$CLOUDXR_DIR/$DEFAULT_CLOUDXR_JS_ARCHIVE" "CloudXR.js package"; then
        return 1
    fi

    CLOUDXR_JS_PACKAGE="$CLOUDXR_DIR/$DEFAULT_CLOUDXR_JS_ARCHIVE"
}

cloudxr_js_npm_install() {
    (cd "$CLOUDXR_JS_SAMPLE_DIR" && npm --registry https://registry.npmjs.org/ install "$@")
}

setup_cloudxr_js() {
    echo -e "\n${BLUE}Setting up CloudXR.js local development sample...${NC}"

    if ! ensure_cloudxr_js_package; then
        return 1
    fi

    if ! check_node_version; then
        return 1
    fi
    if [ ! -f "$CLOUDXR_JS_SAMPLE_DIR/package.json" ]; then
        if [ -d "$CLOUDXR_JS_SAMPLES_DIR" ]; then
            echo -e "${RED}❌ ${CLOUDXR_JS_SAMPLES_DIR} exists but the React sample was not found${NC}"
            echo -e "${YELLOW}Remove it and rerun: rm -rf \"$CLOUDXR_JS_SAMPLES_DIR\" && ./build.sh${NC}"
            return 1
        fi

        echo -e "${YELLOW}Cloning CloudXR.js samples...${NC}"
        if ! git clone --depth 1 "$CLOUDXR_JS_SAMPLES_REPO" "$CLOUDXR_JS_SAMPLES_DIR"; then
            echo -e "${RED}❌ Failed to clone CloudXR.js samples${NC}"
            rm -rf "$CLOUDXR_JS_SAMPLES_DIR"
            return 1
        fi
    else
        echo -e "${GREEN}✓ Using existing CloudXR.js samples in ${CLOUDXR_JS_SAMPLES_DIR}${NC}"
    fi

    echo -e "${GREEN}✓ CloudXR.js React sample directory: ${CLOUDXR_JS_SAMPLE_DIR}${NC}"
    echo -e "${YELLOW}Installing CloudXR.js package from ${CLOUDXR_JS_PACKAGE}...${NC}"
    if ! cloudxr_js_npm_install "../../$(basename "$CLOUDXR_JS_PACKAGE")"; then
        echo -e "${RED}❌ CloudXR.js package install failed${NC}"
        return 1
    fi

    echo -e "${YELLOW}Installing CloudXR.js sample dependencies...${NC}"
    if ! cloudxr_js_npm_install; then
        echo -e "${RED}❌ CloudXR.js dependency install failed${NC}"
        return 1
    fi

    echo -e "${YELLOW}Building CloudXR.js React sample...${NC}"
    if ! (cd "$CLOUDXR_JS_SAMPLE_DIR" && npm run build); then
        echo -e "${RED}❌ CloudXR.js sample build failed${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ CloudXR.js setup complete${NC}"
}

# =============================================================================
# Early Node.js check (CloudXR.js setup runs after the build; fail fast here)
# =============================================================================

if [ "$WITH_CLOUDXRJS" -eq 1 ]; then
    echo -e "\n${YELLOW}Checking Node.js for CloudXR.js setup...${NC}"
    if ! check_node_version; then
        echo -e "${RED}❌ Node.js v${MIN_NODE_VERSION}+ is required for CloudXR.js setup.${NC}"
        echo -e "${YELLOW}  Install from: https://nodejs.org/en/download${NC}"
        echo -e "${YELLOW}  Or skip CloudXR.js setup with: ./build.sh --without-cloudxrjs${NC}"
        exit 1
    fi
fi

# =============================================================================
# Install LÖVR Linux build dependencies
# =============================================================================

echo -e "\n${YELLOW}Checking LÖVR Linux build dependencies...${NC}"
if ! install_lovr_build_dependencies; then
    exit 1
fi

# =============================================================================
# Verify CloudXR SDK
# =============================================================================

echo -e "\n${YELLOW}Checking CloudXR SDK installation...${NC}"
ensure_cloudxr_sdk

# =============================================================================
# Fetch LOVR if not present
# =============================================================================

if [ ! -d "build/src" ]; then
    echo -e "\n${BLUE}Fetching LOVR...${NC}"
    mkdir -p build

    # Pick clone args based on which ref was requested. For an arbitrary commit
    # we need the full history, so we clone first and then check out + init
    # submodules in a second step.
    CLONE_ARGS=()
    if [ -n "$LOVR_BRANCH" ]; then
        CLONE_ARGS=(--depth 1 --branch "$LOVR_BRANCH" --recurse-submodules)
        REF_LABEL="branch ${LOVR_BRANCH}"
    elif [ -n "$LOVR_COMMIT" ]; then
        REF_LABEL="commit ${LOVR_COMMIT}"
    else
        CLONE_ARGS=(--recurse-submodules)
        REF_LABEL="default branch"
    fi

    echo -e "${YELLOW}Cloning from: ${LOVR_REPO} (${REF_LABEL})${NC}"
    if ! git clone "${CLONE_ARGS[@]}" "$LOVR_REPO" build/src; then
        echo -e "${RED}❌ Failed to clone LOVR${NC}"
        exit 1
    fi

    if [ -n "$LOVR_COMMIT" ]; then
        echo -e "${YELLOW}Checking out commit ${LOVR_COMMIT}...${NC}"
        if ! ( cd build/src && git checkout "$LOVR_COMMIT" && git submodule update --init --recursive ); then
            echo -e "${RED}❌ Failed to check out ${LOVR_COMMIT} with submodules${NC}"
            exit 1
        fi
    fi
    echo -e "${GREEN}✓ LOVR ready in build/src/ (with submodules)${NC}"
else
    echo -e "\n${BLUE}Using existing LOVR in build/src/${NC}"
    if ! ( cd build/src && git submodule update --init --recursive ); then
        echo -e "${RED}❌ Failed to update LOVR submodules${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Submodules updated${NC}"
fi

# =============================================================================
# Copy plugin into LOVR
# =============================================================================

echo -e "\n${BLUE}Installing CloudXR plugin...${NC}"
rm -rf build/src/plugins/nvidia
ln -s "$(pwd)/plugins/nvidia" build/src/plugins/nvidia
echo -e "${GREEN}✓ Plugin linked to build/src/plugins/nvidia/${NC}"

# =============================================================================
# Configure CMake
# =============================================================================

echo -e "\n${BLUE}Configuring CMake (${BUILD_TYPE} build)...${NC}"

# CMAKE_ENABLE_EXPORTS=ON       - Enable symbol exports from the LOVR executable
# LOVR_BUILD_WITH_SYMBOLS=ON    - Export all symbols (not just the subset normally marked for export)
# LOVR_USE_STEAM_AUDIO=OFF      - Avoid Steam Audio's vendored mysofa/zlib build issue
if ! cmake -B build -S build/src \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCMAKE_ENABLE_EXPORTS=ON \
    -DLOVR_BUILD_WITH_SYMBOLS=ON \
    -DLOVR_USE_STEAM_AUDIO=OFF \
    -DCLOUDXR_INCLUDE_PATH="$(pwd)/${CLOUDXR_SDK_INCLUDE_DIR}" \
    -DCLOUDXR_LIB_PATH="$(pwd)/${CLOUDXR_SDK_LIB_DIR}" \
    "${CMAKE_EXTRA_ARGS[@]}"; then
    echo -e "${RED}❌ CMake configuration failed${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Configuration complete${NC}"

# =============================================================================
# Build
# =============================================================================

echo -e "\n${BLUE}Building LOVR with CloudXR plugin...${NC}"
echo -e "${YELLOW}This may take a few minutes on first build...${NC}"

if ! cmake --build build --config "${BUILD_TYPE}" -j"$(nproc 2>/dev/null || echo 4)"; then
    echo -e "${RED}❌ Build failed${NC}"
    exit 1
fi

if [ "$WITH_CLOUDXRJS" -eq 1 ]; then
    if ! setup_cloudxr_js; then
        exit 1
    fi
fi

# =============================================================================
# Success
# =============================================================================

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Build complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e ""
echo -e "${BLUE}Run the example:${NC}"
echo -e "  ${YELLOW}./run.sh${NC}                                  # Apple Vision Pro (default)"
echo -e "  ${YELLOW}./run.sh --device-profile=auto-webrtc${NC}     # via CloudXR.js"
echo -e ""
echo -e "${BLUE}See README.md for advanced options and other device profiles.${NC}"
