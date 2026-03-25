# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: MIT

cmake_minimum_required(VERSION 3.10)

# NVIDIA CloudXR Plugin for LÖVR
project(lovr-nvidia-plugin)

# Set Lua include path explicitly
set(LUA_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../deps/lua")
set(LUA_FOUND TRUE)

# Platform-specific library paths
if(WIN32)
    set(CLOUDXR_LIB_PATH "${CMAKE_CURRENT_SOURCE_DIR}/lib/windows-x86_64")
else()
    set(CLOUDXR_LIB_PATH "${CMAKE_CURRENT_SOURCE_DIR}/lib/linux-x86_64")
endif()

# Create the plugin library
add_library(nvidia SHARED
    src/nvidia_cloudxr_runtime.c
    src/nvidia_cloudxr_opaque_data.c
    src/l_nvidia_cloudxr.c
)

# Set the plugin target property for the main CMakeLists.txt to discover
set_property(DIRECTORY PROPERTY LOVR_PLUGIN_TARGETS nvidia)

# Set include directories - the main project will handle additional includes
target_include_directories(nvidia PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_SOURCE_DIR}/deps/openxr/include
    ${CMAKE_SOURCE_DIR}/src
    ${CMAKE_SOURCE_DIR}/src/modules
    ${CMAKE_SOURCE_DIR}/src/lib/std
    ${CMAKE_SOURCE_DIR}/etc
)

# Link against LÖVR libraries and main lovr target for exported symbols
target_link_libraries(nvidia lovr ${LOVR_LUA} ${LOVR_OPENXR})

# Set RPATH for the nvidia plugin to use relative paths
set_target_properties(nvidia PROPERTIES
    BUILD_WITH_INSTALL_RPATH TRUE
    INSTALL_RPATH "$ORIGIN"
    BUILD_WITH_INSTALL_NAME_DIR TRUE
)

# Platform-specific settings
if(WIN32)
    target_compile_definitions(nvidia PRIVATE _WIN32)
    # Ensure we're importing, not exporting global variables
    target_compile_definitions(nvidia PRIVATE LOVR_API_IMPORT)
    # Copy all CloudXR runtime DLLs to output directory
    add_custom_command(TARGET nvidia POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E echo "Copying CloudXR runtime DLLs..."
        # Copy all DLLs from lib directory to main executable directory
        COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${CLOUDXR_LIB_PATH}
        $<TARGET_FILE_DIR:lovr>
        COMMAND ${CMAKE_COMMAND} -E echo "All CloudXR runtime DLLs copied successfully"
    )
else()
    # For Linux, set RPATH and copy the .so file
    # Note: We don't set RPATH here to avoid overriding the main executable's RPATH
    # The main executable will handle library loading with relative paths
    
    # Copy all CloudXR libraries to the main output directory
    # The SDK libraries already ship with correct $ORIGIN RPATH, and cp -a preserves it
    add_custom_command(TARGET nvidia POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E echo "Copying CloudXR Linux libraries preserving symlinks..."
        # Call cp directly (not through bash -c) to preserve symlinks and RPATH
        COMMAND cp -a ${CLOUDXR_LIB_PATH}/. ${CMAKE_BINARY_DIR}/bin/
        COMMAND ${CMAKE_COMMAND} -E echo "All CloudXR Linux libraries copied successfully"
    )
    
    # Copy the nvidia plugin to the main output directory with correct name and fix RPATH
    add_custom_command(TARGET nvidia POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E echo "Copying nvidia plugin to output directory..."
        COMMAND ${CMAKE_COMMAND} -E copy
            $<TARGET_FILE:nvidia>
            ${CMAKE_BINARY_DIR}/bin/nvidia.so
        COMMAND ${CMAKE_COMMAND} -E echo "Nvidia plugin copied successfully"
        # RPATH is set via target properties, no need for manual chrpath
        COMMAND ${CMAKE_COMMAND} -E echo "Nvidia plugin RPATH fixed"
    )
endif()

# Install target
install(TARGETS nvidia
    LIBRARY DESTINATION lib/lovr
    RUNTIME DESTINATION bin
)

# Install headers
install(DIRECTORY include/ DESTINATION include/lovr-nvidia) 