#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: MIT
#
# =============================================================================
# CloudXR LOVR Run Script for Linux
# =============================================================================
# Convenience script to run the CloudXR example
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
DEVICE_PROFILE=""
for arg in "$@"; do
    case $arg in
        --webrtc)
            DEVICE_PROFILE="--webrtc"
            shift
            ;;
        --help|-h)
            echo "Usage: ./run.sh [options]"
            echo ""
            echo "Options:"
            echo "  --webrtc    Use Quest 3 device profile (Early Access)"
            echo "  --help      Show this help message"
            echo ""
            exit 0
            ;;
    esac
done

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
EXAMPLE_PATH="build/src/plugins/nvidia/examples/cloudxr"
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
    echo ""
    echo -e "${YELLOW}If no other instances of CloudXR Runtime are running, you can run:${NC}"
    echo -e "${GREEN}  rm \"$RUNTIME_STARTED_FILE\"${NC}"
    echo -e "${YELLOW}and try again.${NC}"
    echo ""
    exit 1
fi

# Set up CloudXR runtime environment
RUNTIME_JSON="$(pwd)/$(dirname "$LOVR_BIN")/openxr_cloudxr.json"
if [ ! -f "$RUNTIME_JSON" ]; then
    # Try to find it in the source lib directory
    SOURCE_RUNTIME_JSON="$(pwd)/plugins/nvidia/lib/linux-x86_64/openxr_cloudxr.json"
    if [ -f "$SOURCE_RUNTIME_JSON" ]; then
        echo -e "${YELLOW}Copying openxr_cloudxr.json to build directory...${NC}"
        cp "$SOURCE_RUNTIME_JSON" "$(dirname "$LOVR_BIN")/openxr_cloudxr.json"
        RUNTIME_JSON="$(pwd)/$(dirname "$LOVR_BIN")/openxr_cloudxr.json"
    else
        echo -e "${RED}❌ openxr_cloudxr.json not found!${NC}"
        echo -e "${YELLOW}Please ensure the CloudXR SDK files are properly installed.${NC}"
        echo -e "${YELLOW}The openxr_cloudxr.json file should be in:${NC}"
        echo -e "  plugins/nvidia/lib/linux-x86_64/openxr_cloudxr.json${NC}"
        exit 1
    fi
fi

# Convert to absolute path
RUNTIME_JSON="$(realpath "$RUNTIME_JSON")"

# Set OpenXR runtime to CloudXR
export XR_RUNTIME_JSON="$RUNTIME_JSON"

# Run
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Running CloudXR LOVR Example${NC}"
echo -e "${BLUE}========================================${NC}"
if [ -n "$DEVICE_PROFILE" ]; then
    echo -e "${YELLOW}Device Profile: Quest 3 (Early Access)${NC}"
fi
echo -e "${YELLOW}XR Runtime JSON: $XR_RUNTIME_JSON${NC}"
echo -e "${GREEN}Starting LOVR...${NC}"
echo ""

cd "$(dirname "$LOVR_BIN")"
EXAMPLE_REL_PATH="$(realpath --relative-to="$(pwd)" "$EXAMPLE_ABS_PATH")"
"./$(basename "$LOVR_BIN")" "$EXAMPLE_REL_PATH" $DEVICE_PROFILE

echo ""
echo -e "${GREEN}✓ LOVR exited${NC}"

