#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: MIT
#
# =============================================================================
# CloudXR LOVR Build Script for Linux
# =============================================================================
# Usage:
#   ./build.sh                                      - Build with default LOVR
#   ./build.sh Release                              - Build in Release mode
#   ./build.sh clean                                - Clean everything
#   ./build.sh cleanall                             - Clean including src/
#   ./build.sh --lovr-repo <url> --lovr-branch <branch>  - Use custom LOVR branch
#   ./build.sh --lovr-repo <url> --lovr-commit <commit>  - Use custom LOVR commit
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
LOVR_COMMIT="7d47902f594334b9709bfd819cd20514addefbaf"
LOVR_BRANCH=""
CMAKE_EXTRA_ARGS=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        clean)
            echo -e "${YELLOW}Cleaning build directory (keeping source)...${NC}"
            find build -mindepth 1 -maxdepth 1 ! -name 'src' -exec rm -rf {} + 2>/dev/null || true
            echo -e "${GREEN}✓ Clean complete (build/src preserved)${NC}"
            echo -e "\n${BLUE}Run ./build.sh to rebuild${NC}"
            exit 0
            ;;
        cleanall)
            echo -e "${YELLOW}Cleaning entire build directory...${NC}"
            rm -rf build
            echo -e "${GREEN}✓ Clean complete${NC}"
            echo -e "\n${BLUE}Run ./build.sh to rebuild${NC}"
            exit 0
            ;;
        --lovr-repo)
            LOVR_REPO="$2"
            shift 2
            ;;
        --lovr-branch)
            LOVR_BRANCH="$2"
            LOVR_COMMIT=""
            shift 2
            ;;
        --lovr-commit)
            LOVR_COMMIT="$2"
            LOVR_BRANCH=""
            shift 2
            ;;
        Debug|Release|RelWithDebInfo|MinSizeRel)
            BUILD_TYPE="$1"
            shift
            ;;
        *)
            CMAKE_EXTRA_ARGS="$CMAKE_EXTRA_ARGS $1"
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
else
    echo -e "${BLUE}LOVR Commit: ${LOVR_COMMIT}${NC}"
fi
echo -e "${BLUE}Build Type: ${BUILD_TYPE}${NC}"
echo -e "${BLUE}========================================${NC}"

# =============================================================================
# Helper function to extract and setup CloudXR SDK
# =============================================================================

extract_cloudxr_sdk() {
    echo -e "${YELLOW}CloudXR SDK not found in plugins directory. Searching for SDK archive...${NC}"
    
    # Find CloudXR SDK archive
    local sdk_archive=$(ls CloudXR-*-Linux-sdk.tar.gz 2>/dev/null | head -n 1)
    
    if [ -z "$sdk_archive" ]; then
        echo -e "${RED}❌ CloudXR SDK archive not found!${NC}"
        echo -e "${YELLOW}Please download CloudXR SDK from:${NC}"
        echo -e "   https://catalog.ngc.nvidia.com/orgs/nvidia/collections/cloudxr-sdk"
        echo -e ""
        echo -e "${YELLOW}Place the CloudXR-*-Linux-sdk.tar.gz file in the project root${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Found SDK archive: ${sdk_archive}${NC}"
    echo -e "${YELLOW}Extracting SDK...${NC}"
    
    # Determine extraction directory
    local sdk_dir="build/${sdk_archive%.tar.gz}"
    
    # Create extraction directory if it doesn't exist
    mkdir -p "$sdk_dir"
    
    # Extract the archive into build directory, stripping the top-level directory
    tar -xzf "$sdk_archive" -C "$sdk_dir" --strip-components=1
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to extract SDK archive${NC}"
        exit 1
    fi
    
    if [ ! -d "$sdk_dir" ]; then
        echo -e "${RED}❌ Extracted SDK directory not found: ${sdk_dir}${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ SDK extracted to: ${sdk_dir}${NC}"
    echo -e "${YELLOW}Copying SDK files to plugin directories...${NC}"
    
    # Create target directories if they don't exist
    mkdir -p plugins/nvidia/include
    mkdir -p plugins/nvidia/lib/linux-x86_64
    
    # Copy include directory contents
    if [ -d "$sdk_dir/include" ]; then
        echo -e "${YELLOW}  Copying headers...${NC}"
        cp -r "$sdk_dir/include/"* plugins/nvidia/include/
        echo -e "${GREEN}  ✓ Headers copied to plugins/nvidia/include/${NC}"
    else
        echo -e "${RED}❌ Include directory not found in SDK${NC}"
        exit 1
    fi
    
    # Copy everything else (excluding include directory) to lib/linux-x86_64
    echo -e "${YELLOW}  Copying libraries and other files...${NC}"
    for item in "$sdk_dir"/*; do
        if [ "$(basename "$item")" != "include" ]; then
            cp -r "$item" plugins/nvidia/lib/linux-x86_64/
        fi
    done
    echo -e "${GREEN}  ✓ Libraries copied to plugins/nvidia/lib/linux-x86_64/${NC}"
    
    echo -e "${GREEN}✓ CloudXR SDK setup complete!${NC}"
}

# =============================================================================
# Verify CloudXR SDK
# =============================================================================

echo -e "\n${YELLOW}Checking CloudXR SDK installation...${NC}"

if [ ! -f "plugins/nvidia/include/cxrServiceAPI.h" ]; then
    extract_cloudxr_sdk
fi

echo -e "${GREEN}✓ CloudXR SDK headers found${NC}"

# Check for libraries (should have been extracted with headers)
if [ -z "$(ls -A plugins/nvidia/lib/linux-x86_64/*.so* 2>/dev/null)" ]; then
    extract_cloudxr_sdk
fi

echo -e "${GREEN}✓ CloudXR SDK libraries found${NC}"

# =============================================================================
# Fetch LOVR if not present
# =============================================================================

if [ ! -d "build/src" ]; then
    echo -e "\n${BLUE}Fetching LOVR...${NC}"
    mkdir -p build
    if [ -n "${LOVR_BRANCH}" ]; then
        echo -e "${YELLOW}Cloning from: ${LOVR_REPO} (branch ${LOVR_BRANCH})${NC}"
        git clone --depth 1 --branch "${LOVR_BRANCH}" --recurse-submodules "${LOVR_REPO}" build/src

        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ Failed to clone LOVR${NC}"
            exit 1
        fi

        echo -e "${GREEN}✓ LOVR cloned successfully with submodules${NC}"
    else
        echo -e "${YELLOW}Cloning from: ${LOVR_REPO} (commit ${LOVR_COMMIT})${NC}"
        git clone "${LOVR_REPO}" build/src

        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ Failed to clone LOVR${NC}"
            exit 1
        fi

        echo -e "${YELLOW}Checking out commit ${LOVR_COMMIT}...${NC}"
        cd build/src
        git checkout "${LOVR_COMMIT}"

        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ Failed to checkout commit ${LOVR_COMMIT}${NC}"
            cd ../..
            exit 1
        fi

        git submodule update --init --recursive

        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ Failed to initialize submodules${NC}"
            cd ../..
            exit 1
        fi

        cd ../..
        echo -e "${GREEN}✓ LOVR cloned and checked out successfully with submodules${NC}"
    fi
else
    echo -e "\n${BLUE}Using existing LOVR in build/src/${NC}"
    echo -e "${YELLOW}Updating submodules...${NC}"
    cd build/src
    git submodule update --init --recursive
    cd ../..
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

# CMAKE_ENABLE_EXPORTS=ON - Enable symbol exports from the LOVR executable
# LOVR_BUILD_WITH_SYMBOLS=ON - Export all symbols (not just the subset normally marked for export)
cmake -B build -S build/src -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" -DCMAKE_ENABLE_EXPORTS=ON -DLOVR_BUILD_WITH_SYMBOLS=ON $CMAKE_EXTRA_ARGS

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ CMake configuration failed${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Configuration complete${NC}"

# =============================================================================
# Build
# =============================================================================

echo -e "\n${BLUE}Building LOVR with CloudXR plugin...${NC}"
echo -e "${YELLOW}This may take a few minutes on first build...${NC}"

cmake --build build --config "${BUILD_TYPE}" -j$(nproc 2>/dev/null || echo 4)

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Build failed${NC}"
    exit 1
fi

# =============================================================================
# Success
# =============================================================================

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Build Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e ""
echo -e "${BLUE}Directory structure:${NC}"
echo -e "  build/src/        - LOVR source with CloudXR plugin"
echo -e "  build/bin/        - Build output (Linux)"
echo -e ""
echo -e "${BLUE}To run the CloudXR example:${NC}"
echo -e "  ${YELLOW}./run.sh${NC}"
echo -e ""
echo -e "${BLUE}Or manually:${NC}"
echo -e "  cd build/bin"
echo -e "  ./lovr ../src/plugins/nvidia/examples/cloudxr"
echo -e ""
echo -e "${BLUE}For Quest 3 (Early Access):${NC}"
echo -e "  ./run.sh --webrtc"
echo -e ""

