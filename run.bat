@echo off
REM SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
REM SPDX-License-Identifier: MIT
REM
REM =============================================================================
REM CloudXR LOVR Run Script for Windows
REM =============================================================================
REM Convenience script to run the CloudXR example
REM =============================================================================

setlocal enabledelayedexpansion

REM Parse arguments
set DEVICE_PROFILE=
:parse_args
if "%1"=="" goto :done_parsing
if "%1"=="--webrtc" (
    set DEVICE_PROFILE=--webrtc
    shift
    goto :parse_args
)
if "%1"=="--help" goto :show_help
if "%1"=="-h" goto :show_help
shift
goto :parse_args

:show_help
echo Usage: run.bat [options]
echo.
echo Options:
echo   --webrtc    Use Quest 3 device profile (Early Access^)
echo   --help      Show this help message
echo.
exit /b 0

:done_parsing

REM Check if build\src exists
if not exist "build\src" (
    echo ERROR: build\src\ directory not found!
    echo Run build.bat first to build the project
    exit /b 1
)

REM Detect build configuration
set LOVR_BIN=
set BUILD_CONFIG=

if exist "build\Debug\lovr.exe" (
    set LOVR_BIN=build\Debug\lovr.exe
    set BUILD_CONFIG=Debug
) else if exist "build\Release\lovr.exe" (
    set LOVR_BIN=build\Release\lovr.exe
    set BUILD_CONFIG=Release
) else (
    echo ERROR: Build output not found!
    echo Run build.bat first to build the project
    exit /b 1
)

REM Check if LOVR executable exists
if not exist "%LOVR_BIN%" (
    echo ERROR: LOVR executable not found at: %LOVR_BIN%
    echo Run build.bat first to build the project
    exit /b 1
)

REM Check if example exists
set EXAMPLE_PATH=build\src\plugins\nvidia\examples\cloudxr
if not exist "%EXAMPLE_PATH%" (
    echo ERROR: CloudXR example not found at: %EXAMPLE_PATH%
    exit /b 1
)

REM Run
echo ========================================
echo Running CloudXR LOVR Example
echo ========================================
if defined DEVICE_PROFILE (
    echo Device Profile: Quest 3 (Early Access^)
)
echo Starting LOVR...
echo.

REM Set OpenXR runtime to CloudXR
set XR_RUNTIME_JSON=%CD%\build\%BUILD_CONFIG%\openxr_cloudxr.json
echo XR_RUNTIME_JSON: %XR_RUNTIME_JSON%
echo.

cd /d "build\%BUILD_CONFIG%"
lovr.exe "..\src\plugins\nvidia\examples\cloudxr" %DEVICE_PROFILE%

echo.
echo LOVR exited

