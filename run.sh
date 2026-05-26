#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: MIT
#
# =============================================================================
# CloudXR LOVR Run Script for Linux
# =============================================================================
# Quick reference (see README.md for full docs):
#   ./run.sh                                Apple Vision Pro (default)
#   ./run.sh --device-profile=auto-webrtc   via CloudXR.js
#   ./run.sh --without-cloudxrjs            Skip the local CloudXR.js dev
#                                           server (use your own server)
#   ./run.sh --cert <pem> --key <pem>       Enable native TLS (wss://)
# These flags are consumed here; anything else is forwarded to LÖVR unchanged.
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse --cert/--key; forward all other args to Lua unchanged.
CERT_PATH=""
KEY_PATH=""
POSITIONAL_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --cert)
            if [ -z "$2" ] || [ "${2#-}" != "$2" ]; then
                echo -e "${RED}❌ Missing path after --cert${NC}" >&2
                exit 1
            fi
            CERT_PATH="$2"
            shift 2
            ;;
        --key)
            if [ -z "$2" ] || [ "${2#-}" != "$2" ]; then
                echo -e "${RED}❌ Missing path after --key${NC}" >&2
                exit 1
            fi
            KEY_PATH="$2"
            shift 2
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL_ARGS[@]}"

# Normalize TLS inputs (flag values override env), then validate and re-export.
CERT_PATH="${CERT_PATH:-$CLOUDXR_CERT_PATH}"
KEY_PATH="${KEY_PATH:-$CLOUDXR_KEY_PATH}"
if [ -n "$CERT_PATH" ] || [ -n "$KEY_PATH" ]; then
    if [ -z "$CERT_PATH" ] || [ -z "$KEY_PATH" ]; then
        echo -e "${RED}❌ --cert and --key must be provided together${NC}"
        exit 1
    fi
    if [ ! -f "$CERT_PATH" ]; then
        echo -e "${RED}❌ Certificate file not found: $CERT_PATH${NC}"
        exit 1
    fi
    if [ ! -f "$KEY_PATH" ]; then
        echo -e "${RED}❌ Key file not found: $KEY_PATH${NC}"
        exit 1
    fi
    if ! CERT_REAL_PATH="$(realpath "$CERT_PATH")"; then
        echo -e "${RED}❌ Failed to resolve certificate path: $CERT_PATH${NC}" >&2
        exit 1
    fi
    if ! KEY_REAL_PATH="$(realpath "$KEY_PATH")"; then
        echo -e "${RED}❌ Failed to resolve key path: $KEY_PATH${NC}" >&2
        exit 1
    fi
    export CLOUDXR_CERT_PATH="$CERT_REAL_PATH"
    export CLOUDXR_KEY_PATH="$KEY_REAL_PATH"
fi

CLOUDXR_JS_SAMPLE_DIR="build/cloudxr/cloudxr-js-samples/react"
CLOUDXR_JS_DEV_SERVER_LOG="build/cloudxr/cloudxr-js-dev-server.log"
CLOUDXR_JS_DEV_SERVER_PORT=8080
CLOUDXR_JS_DEV_SERVER_PID=""

# Filter our own --without-cloudxrjs flag out of the args before forwarding the
# rest to LÖVR. While we're walking the args, also note whether the user
# selected the auto-webrtc profile (which is what triggers the local dev
# server) so we don't have to walk twice.
WITHOUT_CLOUDXRJS=0
USES_AUTO_WEBRTC=0
LOVR_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --without-cloudxrjs)
            WITHOUT_CLOUDXRJS=1
            ;;
        --device-profile=auto-webrtc)
            USES_AUTO_WEBRTC=1
            LOVR_ARGS+=("$arg")
            ;;
        *)
            LOVR_ARGS+=("$arg")
            ;;
    esac
done

cleanup_cloudxr_js_dev_server() {
    local pid="$CLOUDXR_JS_DEV_SERVER_PID"
    CLOUDXR_JS_DEV_SERVER_PID=""

    if [ -n "$pid" ]; then
        echo -e "${YELLOW}Stopping CloudXR.js dev server...${NC}"
        kill -- -"$pid" 2>/dev/null || true
        kill "$pid" 2>/dev/null || true
        sleep 1
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 -- -"$pid" 2>/dev/null || true
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi

    if command -v fuser >/dev/null 2>&1; then
        local port_pids=""
        port_pids="$(fuser "${CLOUDXR_JS_DEV_SERVER_PORT}/tcp" 2>/dev/null || true)"
        if [ -n "$port_pids" ]; then
            echo -e "${YELLOW}Port ${CLOUDXR_JS_DEV_SERVER_PORT} is still in use by PID(s): $port_pids${NC}"
            echo -e "${YELLOW}Not killing those processes because they may not belong to this run.${NC}"
        fi
    fi
}

start_cloudxr_js_dev_server() {
    if [ ! -f "$CLOUDXR_JS_SAMPLE_DIR/package.json" ]; then
        echo -e "${YELLOW}⚠️  CloudXR.js React sample not found at: $CLOUDXR_JS_SAMPLE_DIR${NC}"
        echo -e "${YELLOW}Re-run ./build.sh (without --without-cloudxrjs) to set it up,${NC}"
        echo -e "${YELLOW}or run with --without-cloudxrjs if you have your own server.${NC}"
        return 0
    fi

    if ! command -v npm >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️  npm was not found; skipping local CloudXR.js dev server.${NC}"
        echo -e "${YELLOW}Install Node.js v20.19.0+ to run the local server, or use your own.${NC}"
        return 0
    fi

    # If port 8080 is already taken, assume an existing CloudXR.js server
    # (intentional or an orphan from a previous run) is serving it and skip
    # rather than failing noisily on EADDRINUSE.
    if command -v fuser >/dev/null 2>&1; then
        local existing_pids=""
        existing_pids="$(fuser "${CLOUDXR_JS_DEV_SERVER_PORT}/tcp" 2>/dev/null || true)"
        if [ -n "$existing_pids" ]; then
            echo -e "${YELLOW}⚠️  Port ${CLOUDXR_JS_DEV_SERVER_PORT} is already in use by PID(s): ${existing_pids}${NC}"
            echo -e "${YELLOW}Skipping local dev server; assuming an existing CloudXR.js server is serving it.${NC}"
            echo -e "${YELLOW}If that's an orphan from a previous run, stop it with:${NC}"
            echo -e "${GREEN}  fuser -k ${CLOUDXR_JS_DEV_SERVER_PORT}/tcp${NC}"
            return 0
        fi
    fi

    mkdir -p "$(dirname "$CLOUDXR_JS_DEV_SERVER_LOG")"
    local log_path
    log_path="$(pwd)/$CLOUDXR_JS_DEV_SERVER_LOG"

    # Register the cleanup trap before launching so a Ctrl-C between fork
    # and PID capture still tears the process group down.
    trap cleanup_cloudxr_js_dev_server EXIT INT TERM

    echo -e "${BLUE}Starting CloudXR.js dev server...${NC}"
    local cloudxr_js_pkg_json="$CLOUDXR_JS_SAMPLE_DIR/node_modules/@nvidia/cloudxr/package.json"
    if [ -f "$cloudxr_js_pkg_json" ]; then
        local cloudxr_js_version
        cloudxr_js_version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cloudxr_js_pkg_json" | head -n1)"
        if [ -n "$cloudxr_js_version" ]; then
            echo -e "${YELLOW}CloudXR.js version: $cloudxr_js_version${NC}"
        fi
    fi
    echo -e "${YELLOW}CloudXR.js directory: $CLOUDXR_JS_SAMPLE_DIR${NC}"
    echo -e "${YELLOW}CloudXR.js log: $CLOUDXR_JS_DEV_SERVER_LOG${NC}"
    setsid sh -c 'cd "$1" && exec npm run dev-server > "$2" 2>&1' sh "$CLOUDXR_JS_SAMPLE_DIR" "$log_path" &
    CLOUDXR_JS_DEV_SERVER_PID=$!

    sleep 2
    if ! kill -0 "$CLOUDXR_JS_DEV_SERVER_PID" 2>/dev/null; then
        CLOUDXR_JS_DEV_SERVER_PID=""
        echo -e "${YELLOW}⚠️  CloudXR.js dev server failed to start; continuing without it. Last log lines:${NC}"
        tail -n 40 "$CLOUDXR_JS_DEV_SERVER_LOG" 2>/dev/null || true
        return 0
    fi

    echo -e "${GREEN}✓ CloudXR.js dev server started (pid $CLOUDXR_JS_DEV_SERVER_PID)${NC}"
}


# Check if build/src exists
if [ ! -d "build/src" ]; then
    echo -e "${RED}❌ build/src/ directory not found!${NC}"
    echo -e "${YELLOW}Run ./build.sh first to build the project${NC}"
    exit 1
fi

# Detect build configuration
if [ -d "build/bin" ]; then
    LOVR_BIN="build/bin/lovr"
elif [ -d "build/Debug" ]; then
    LOVR_BIN="build/Debug/lovr"
elif [ -d "build/Release" ]; then
    LOVR_BIN="build/Release/lovr"
else
    echo -e "${RED}❌ Build output not found!${NC}"
    echo -e "${YELLOW}Run ./build.sh first to build the project${NC}"
    exit 1
fi

# Check if LOVR executable exists
if [ ! -f "$LOVR_BIN" ]; then
    echo -e "${RED}❌ LOVR executable not found at: $LOVR_BIN${NC}"
    echo -e "${YELLOW}Run ./build.sh first to build the project${NC}"
    exit 1
fi

# Check if example exists
EXAMPLE_PATH="plugins/nvidia/examples/cloudxr"
if [ ! -d "$EXAMPLE_PATH" ]; then
    echo -e "${RED}❌ CloudXR example not found at: $EXAMPLE_PATH${NC}"
    exit 1
fi

# Convert example path to absolute path before changing directories
EXAMPLE_ABS_PATH="$(realpath "$EXAMPLE_PATH")"

# Check for existing runtime_started file
# Mirror the runtime's logic for determining runtime directory
if [ -n "$XDG_RUNTIME_DIR" ]; then
    RUNTIME_DIR="$XDG_RUNTIME_DIR"
elif [ -n "$XDG_CACHE_HOME" ]; then
    RUNTIME_DIR="$XDG_CACHE_HOME"
else
    RUNTIME_DIR="$HOME/.cache"
fi

RUNTIME_STARTED_FILE="$RUNTIME_DIR/runtime_started"
if [ -f "$RUNTIME_STARTED_FILE" ]; then
    echo -e "${YELLOW}⚠️  CloudXR Runtime service file exists: $RUNTIME_STARTED_FILE${NC}"
    echo -e "${YELLOW}This indicates CloudXR Runtime service is running or a previous instance of the runtime did not exit gracefully.${NC}"
    if [ -t 0 ]; then
        answer=""
        read -r -p "If no other CloudXR Runtime is running, remove the lock file and continue? [y/N] " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            rm -f "$RUNTIME_STARTED_FILE"
            echo -e "${GREEN}✓ Removed ${RUNTIME_STARTED_FILE}${NC}"
        else
            echo -e "${YELLOW}Aborting. Stop the other CloudXR runtime first, or remove the file manually after confirming it is stale:${NC}"
            echo -e "${GREEN}  rm \"$RUNTIME_STARTED_FILE\"${NC}"
            exit 1
        fi
    else
        echo -e "${YELLOW}If no other instances of CloudXR Runtime are running, run:${NC}"
        echo -e "${GREEN}  rm \"$RUNTIME_STARTED_FILE\"${NC}"
        echo -e "${YELLOW}and try again.${NC}"
        exit 1
    fi
fi

# CloudXR runtime manifest is staged into the build output by the CMake
# POST_BUILD step in plugins/nvidia/CMakeLists.txt.
RUNTIME_JSON="$(pwd)/$(dirname "$LOVR_BIN")/openxr_cloudxr.json"
if [ ! -f "$RUNTIME_JSON" ]; then
    echo -e "${RED}❌ openxr_cloudxr.json not found at: $RUNTIME_JSON${NC}"
    echo -e "${YELLOW}Re-run ./build.sh to stage CloudXR runtime files into the build output.${NC}"
    exit 1
fi

# Convert to absolute path
RUNTIME_JSON="$(realpath "$RUNTIME_JSON")"

if [ "$USES_AUTO_WEBRTC" -eq 1 ]; then
    if [ "$WITHOUT_CLOUDXRJS" -eq 1 ]; then
        echo -e "${YELLOW}Skipping local CloudXR.js dev server (--without-cloudxrjs).${NC}"
        echo -e "${YELLOW}Make sure your own CloudXR.js server is reachable.${NC}"
    else
        start_cloudxr_js_dev_server
    fi
fi

# Set OpenXR runtime to CloudXR
export XR_RUNTIME_JSON="$RUNTIME_JSON"

# Run
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Running CloudXR LOVR Example${NC}"
echo -e "${BLUE}========================================${NC}"
if [ -n "$CLOUDXR_CERT_PATH" ]; then
    echo -e "${YELLOW}TLS Cert: $CLOUDXR_CERT_PATH${NC}"
    echo -e "${YELLOW}TLS Key:  $CLOUDXR_KEY_PATH${NC}"
fi
echo -e "${YELLOW}XR Runtime JSON: $XR_RUNTIME_JSON${NC}"
echo -e "${GREEN}Starting LOVR...${NC}"
echo ""

cd "$(dirname "$LOVR_BIN")"
EXAMPLE_REL_PATH="$(realpath --relative-to="$(pwd)" "$EXAMPLE_ABS_PATH")"
"./$(basename "$LOVR_BIN")" "$EXAMPLE_REL_PATH" "${LOVR_ARGS[@]}"

echo ""
echo -e "${GREEN}✓ LOVR exited${NC}"
