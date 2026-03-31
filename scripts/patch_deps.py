#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: MIT
#
# Applies patches to third-party dependencies that are cloned at build time.
# Called by build.sh and build.bat after the LOVR source tree is available.
# Each patch is idempotent: a no-op if already applied or if the target text
# is not found (e.g. the upstream dependency has already been fixed).

import sys
import os


def patch_file(path, replacements):
    """Apply a list of (old, new) string replacements to a file."""
    if not os.path.exists(path):
        print(f"  Skipping: {path} not found")
        return

    with open(path, encoding="utf-8") as f:
        content = f.read()

    changed = False
    for old, new in replacements:
        if new in content:
            continue  # already applied
        if old not in content:
            print(f"  WARNING: patch target not found in {path} - upstream may have changed")
            continue
        content = content.replace(old, new, 1)
        changed = True

    if changed:
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        print(f"  Patched: {path}")
    else:
        print(f"  Already up to date: {path}")


# ---------------------------------------------------------------------------
# mysofa/src/CMakeLists.txt
#
# Problem 1: On MSVC the file unconditionally tries to run `nuget install zlib`
#            even though phonon's own build already provides ZLIB_INCLUDE_DIR.
#            The NuGet package named "zlib" does not exist, so the call fails.
# Problem 2: The hardcoded fallback include path references zlib-1.2.11 but
#            the bundled copy in the repo is zlib-1.3.1.
# ---------------------------------------------------------------------------
MYSOFA_CMAKE = os.path.join(
    "build", "src", "deps", "phonon", "core", "deps", "mysofa", "src", "CMakeLists.txt"
)

# ---------------------------------------------------------------------------
# pffft/cmake/target_optimizations.cmake
#
# Problem: CMAKE_SYSTEM_PROCESSOR is "AMD64" on Windows/MSVC but the x86_64
#          branch only matches "i686" and "x86_64", causing an "unsupported
#          CMAKE_SYSTEM_PROCESSOR" warning and falling through to a degraded
#          no-op configuration.
# Fix: add "AMD64" to the x86_64 condition.
# ---------------------------------------------------------------------------
PFFFT_OPT_CMAKE = os.path.join(
    "build", "src", "deps", "phonon", "core", "deps", "pffft", "cmake", "target_optimizations.cmake"
)

patch_file(PFFFT_OPT_CMAKE, [
    (
        'if ( (CMAKE_SYSTEM_PROCESSOR STREQUAL "i686") OR (CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64") )',
        'if ( (CMAKE_SYSTEM_PROCESSOR STREQUAL "i686") OR (CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64") OR (CMAKE_SYSTEM_PROCESSOR STREQUAL "AMD64") )',
    ),
])

patch_file(MYSOFA_CMAKE, [
    # First MSVC block: guard NuGet call behind ZLIB_INCLUDE_DIR check
    (
        """\
else()
  set(MATH "")
  find_program(NUGET nuget)
  if(NUGET)
    execute_process(COMMAND ${NUGET} install zlib)
  endif()
  include_directories(
    ${PROJECT_SOURCE_DIR}/windows/third-party/zlib-1.2.11/include/)
endif()""",
        """\
else()
  set(MATH "")
  if(NOT ZLIB_INCLUDE_DIR)
    find_program(NUGET nuget)
    if(NUGET)
      execute_process(COMMAND ${NUGET} install zlib)
    endif()
    include_directories(
      ${PROJECT_SOURCE_DIR}/windows/third-party/zlib-1.3.1/include/)
  endif()
endif()""",
    ),
    # Second MSVC block: use ZLIB_INCLUDE_DIR when available; update path otherwise
    (
        """\
else()
  set(MATH "")
  find_program(NUGET nuget)
  if(NOT NUGET)
    message(
      FATAL
      "Cannot find nuget command line tool.\\nInstall it with e.g. choco install nuget.commandline"
    )
  else()
    execute_process(COMMAND ${NUGET} install zlib)
  endif()
  include_directories(
    ${PROJECT_SOURCE_DIR}/windows/third-party/zlib-1.2.11/include/)
endif()""",
        """\
else()
  set(MATH "")
  if(ZLIB_INCLUDE_DIR)
    include_directories(${ZLIB_INCLUDE_DIR})
  else()
    find_program(NUGET nuget)
    if(NOT NUGET)
      message(STATUS "nuget not found; using bundled zlib from windows/third-party/zlib-1.3.1")
    else()
      execute_process(COMMAND ${NUGET} install zlib)
    endif()
    include_directories(
      ${PROJECT_SOURCE_DIR}/windows/third-party/zlib-1.3.1/include/)
  endif()
endif()""",
    ),
])
