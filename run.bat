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

REM Open firewall ports scoped to lovr.exe (only if rules are not already present).
REM Elevates via UAC if not already running as Administrator.
set PS_ARGS=-ExecutionPolicy Bypass -File "%~dp0scripts\open_firewall_ports.ps1" -ExePath "%CD%\%LOVR_BIN%"
powershell -Command "$u = Get-NetFirewallRule -DisplayName 'CloudXR Server (UDP 47998,47999,48000,48002,48005)' -ErrorAction SilentlyContinue; $t = Get-NetFirewallRule -DisplayName 'CloudXR Server (TCP 48010,49100)' -ErrorAction SilentlyContinue; if ($u -and $t) { exit 0 } else { exit 1 }" >nul 2>&1
if not errorlevel 1 (
    echo Firewall rules already configured, skipping.
) else (
    echo Configuring firewall rules for CloudXR...
    net session >nul 2>&1
    if errorlevel 1 (
        REM Not admin - launch an elevated PowerShell and wait for it to finish.
        powershell -Command "Start-Process powershell -ArgumentList '%PS_ARGS%' -Verb RunAs -Wait"
    ) else (
        REM Already admin - run directly.
        powershell %PS_ARGS%
    )
    if errorlevel 1 (
        echo WARNING: Firewall rule setup failed. Ports may need to be opened manually:
        echo          UDP 47998 47999 48000 48002 48005 / TCP 48010 49100
    )
)
echo.

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

