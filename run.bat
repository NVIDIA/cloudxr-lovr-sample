@echo off
REM SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
REM SPDX-License-Identifier: MIT
REM
REM =============================================================================
REM CloudXR LOVR Run Script for Windows
REM =============================================================================
REM Quick reference (see README.md for full docs):
REM   run.bat                                Apple Vision Pro (default)
REM   run.bat --device-profile=auto-webrtc   via CloudXR.js
REM   run.bat --without-cloudxrjs            Skip the local CloudXR.js dev
REM                                          server (use your own server)
REM   run.bat --cert <pem> --key <pem>       Enable native TLS (wss://)
REM These flags are consumed here; anything else is forwarded to LOVR unchanged.
REM =============================================================================

setlocal enabledelayedexpansion

REM Consume --cert/--key, --without-cloudxrjs, and note --device-profile=auto-webrtc.
REM Everything else accumulates in LOVR_ARGS for LOVR. cmd.exe treats '=' as an
REM argument separator, so "--device-profile=auto-webrtc" may arrive as either
REM one arg or two ("--device-profile" + "auto-webrtc"); we match both forms.
set CERT_PATH=
set KEY_PATH=
set "WITHOUT_CLOUDXRJS=0"
set "USES_AUTO_WEBRTC=0"
set "LOVR_ARGS="
:parse_args
if "%~1"=="" goto :done_parsing
if /i "%~1"=="--cert" (
    if "%~2"=="" (
        echo ERROR: Missing path after --cert
        exit /b 1
    )
    set "CERT_PATH=%~2"
    shift
    shift
    goto :parse_args
)
if /i "%~1"=="--key" (
    if "%~2"=="" (
        echo ERROR: Missing path after --key
        exit /b 1
    )
    set "KEY_PATH=%~2"
    shift
    shift
    goto :parse_args
)
if /i "%~1"=="--without-cloudxrjs" (
    set "WITHOUT_CLOUDXRJS=1"
    shift
    goto :parse_args
)
if /i "%~1"=="--device-profile=auto-webrtc" set "USES_AUTO_WEBRTC=1"
if /i "%~1"=="--device-profile" if /i "%~2"=="auto-webrtc" set "USES_AUTO_WEBRTC=1"
set "LOVR_ARGS=!LOVR_ARGS! "%~1""
shift
goto :parse_args
:done_parsing

REM Normalize TLS inputs (flag values override env), then validate and re-export.
if not defined CERT_PATH if defined CLOUDXR_CERT_PATH set "CERT_PATH=%CLOUDXR_CERT_PATH%"
if not defined KEY_PATH if defined CLOUDXR_KEY_PATH set "KEY_PATH=%CLOUDXR_KEY_PATH%"
if defined CERT_PATH (
    if not defined KEY_PATH (
        echo ERROR: --cert and --key must be provided together
        exit /b 1
    )
)
if defined KEY_PATH (
    if not defined CERT_PATH (
        echo ERROR: --cert and --key must be provided together
        exit /b 1
    )
)
if defined CERT_PATH (
    if not exist "%CERT_PATH%" (
        echo ERROR: Certificate file not found: %CERT_PATH%
        exit /b 1
    )
    if not exist "%KEY_PATH%" (
        echo ERROR: Key file not found: %KEY_PATH%
        exit /b 1
    )
    for %%I in ("%CERT_PATH%") do set "CLOUDXR_CERT_PATH=%%~fI"
    for %%I in ("%KEY_PATH%") do set "CLOUDXR_KEY_PATH=%%~fI"
)

set "CLOUDXR_JS_SAMPLE_DIR=%CD%\build\cloudxr\cloudxr-js-samples\react"

REM Check if build\src exists
if not exist "build\src" (
    echo ERROR: build\src\ directory not found!
    echo Run build.bat first to build the project
    exit /b 1
)

REM Detect build configuration
set "LOVR_BIN="
set "BUILD_CONFIG="

if exist "build\Debug\lovr.exe" (
    set "LOVR_BIN=build\Debug\lovr.exe"
    set "BUILD_CONFIG=Debug"
) else if exist "build\Release\lovr.exe" (
    set "LOVR_BIN=build\Release\lovr.exe"
    set "BUILD_CONFIG=Release"
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
set "EXAMPLE_PATH=%CD%\plugins\nvidia\examples\cloudxr"
if not exist "%EXAMPLE_PATH%" (
    echo ERROR: CloudXR example not found at: %EXAMPLE_PATH%
    exit /b 1
)

if "%USES_AUTO_WEBRTC%"=="1" (
    if "%WITHOUT_CLOUDXRJS%"=="1" (
        echo Skipping local CloudXR.js dev server ^(--without-cloudxrjs^).
        echo Make sure your own CloudXR.js server is reachable.
    ) else (
        call :start_cloudxr_js_dev_server
        if errorlevel 1 exit /b 1
    )
)

REM Run
echo ========================================
echo Running CloudXR LOVR Example
echo ========================================
if defined CLOUDXR_CERT_PATH (
    echo TLS Cert: %CLOUDXR_CERT_PATH%
    echo TLS Key:  %CLOUDXR_KEY_PATH%
)
echo Starting LOVR...
echo.

REM Set OpenXR runtime to CloudXR
set "XR_RUNTIME_JSON=%CD%\build\%BUILD_CONFIG%\openxr_cloudxr.json"
echo XR_RUNTIME_JSON: %XR_RUNTIME_JSON%
echo.

cd /d "build\%BUILD_CONFIG%"
lovr.exe "%EXAMPLE_PATH%" %LOVR_ARGS%
set "LOVR_EXIT_CODE=%ERRORLEVEL%"

echo.
echo LOVR exited
exit /b %LOVR_EXIT_CODE%

:start_cloudxr_js_dev_server
if not exist "%CLOUDXR_JS_SAMPLE_DIR%\package.json" (
    echo WARNING: CloudXR.js React sample not found at: %CLOUDXR_JS_SAMPLE_DIR%
    echo Re-run build.bat (without --without-cloudxrjs) to set it up,
    echo or run with --without-cloudxrjs if you have your own server.
    exit /b 0
)
where npm >nul 2>nul
if errorlevel 1 (
    echo WARNING: npm was not found; skipping local CloudXR.js dev server.
    echo Install Node.js v20.19.0+ to run the local server, or use your own.
    exit /b 0
)
REM If port 8080 is already taken, assume an existing CloudXR.js server
REM (intentional or an orphan from a previous run) is serving it and skip
REM rather than failing. Mirrors run.sh behavior.
set "PORT_8080_PID="
for /f "tokens=5" %%P in ('netstat -ano ^| findstr /r /c:":8080 .*LISTENING"') do (
    set "PORT_8080_PID=%%P"
    goto port_8080_check_done
)
:port_8080_check_done
if defined PORT_8080_PID (
    echo WARNING: Port 8080 is already in use by PID !PORT_8080_PID!.
    echo Skipping local dev server; assuming an existing CloudXR.js server is serving it.
    echo If that's an orphan from a previous run, close the leftover "CloudXR.js dev server"
    echo window, or run: taskkill /PID !PORT_8080_PID! /T /F
    exit /b 0
)
echo Starting CloudXR.js dev server in a new window...
set "CLOUDXR_JS_PKG_JSON=%CLOUDXR_JS_SAMPLE_DIR%\node_modules\@nvidia\cloudxr\package.json"
if exist "%CLOUDXR_JS_PKG_JSON%" (
    set "CLOUDXR_JS_VERSION="
    for /f "tokens=2 delims=:" %%A in ('findstr /c:"\"version\"" "%CLOUDXR_JS_PKG_JSON%"') do (
        if not defined CLOUDXR_JS_VERSION (
            set "_RAW=%%A"
            set "_RAW=!_RAW: =!"
            set "_RAW=!_RAW:,=!"
            set "_RAW=!_RAW:"=!"
            set "CLOUDXR_JS_VERSION=!_RAW!"
        )
    )
    if defined CLOUDXR_JS_VERSION echo CloudXR.js version: !CLOUDXR_JS_VERSION!
)
echo CloudXR.js directory: %CLOUDXR_JS_SAMPLE_DIR%
echo NOTE: this window will stay open after run.bat exits. Close it manually
echo       when you're done, or port 8080 will remain in use on the next run.
start "CloudXR.js dev server" /D "%CLOUDXR_JS_SAMPLE_DIR%" cmd /k npm run dev-server
exit /b 0
