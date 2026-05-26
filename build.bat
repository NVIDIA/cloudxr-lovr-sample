@echo off
REM SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
REM SPDX-License-Identifier: MIT
REM
REM =============================================================================
REM CloudXR LOVR Build Script for Windows
REM =============================================================================
REM Quick reference (see README.md for full docs):
REM   build.bat                       Default Debug build with CloudXR.js setup
REM   build.bat Release               Release build
REM   build.bat --without-cloudxrjs   Skip CloudXR.js setup
REM   build.bat --clean               Wipe build\ outputs (keep cached archives)
REM
REM Custom LOVR source (default: pinned commit on github.com/bjornbytes/lovr):
REM   build.bat --lovr-branch <branch>
REM   build.bat --lovr-commit <hash>
REM   build.bat --lovr-repo <url>
REM
REM Any unrecognized argument is forwarded to `cmake` (e.g. -DLOVR_BUILD_BUNDLE=ON).
REM =============================================================================

setlocal enabledelayedexpansion

REM Default values
set "BUILD_TYPE=Debug"
set "LOVR_REPO=https://github.com/bjornbytes/lovr.git"
set "LOVR_COMMIT=fa652681ef736d0ed4e11362fe23125f180eecbf"
set "LOVR_BRANCH="
set "WITH_CLOUDXRJS=1"
set "CMAKE_EXTRA_ARGS="
set "CLOUDXR_DIR=build\cloudxr"

REM CloudXR Runtime / CloudXR.js versions. The build prefers an archive in
REM build\cloudxr\ whose filename matches these versions, falls back to any
REM matching archive, and finally downloads this version if none is present.
REM Override by setting CLOUDXR_RUNTIME_VERSION / CLOUDXR_JS_VERSION in the
REM environment, or edit the defaults below.
if not defined CLOUDXR_RUNTIME_VERSION set "CLOUDXR_RUNTIME_VERSION=6.2.0"
if not defined CLOUDXR_JS_VERSION set "CLOUDXR_JS_VERSION=6.2.0"

set "DEFAULT_CLOUDXR_RUNTIME_ARCHIVE=CloudXR-%CLOUDXR_RUNTIME_VERSION%-Win64-sdk.zip"
set "DEFAULT_CLOUDXR_RUNTIME_URL=https://api.ngc.nvidia.com/v2/resources/org/nvidia/cloudxr-runtime/%CLOUDXR_RUNTIME_VERSION%/files?redirect=true&path=%DEFAULT_CLOUDXR_RUNTIME_ARCHIVE%"
set "DEFAULT_CLOUDXR_JS_ARCHIVE=nvidia-cloudxr-%CLOUDXR_JS_VERSION%.tgz"
set "DEFAULT_CLOUDXR_JS_URL=https://api.ngc.nvidia.com/v2/resources/org/nvidia/cloudxr-js/%CLOUDXR_JS_VERSION%/files?redirect=true&path=%DEFAULT_CLOUDXR_JS_ARCHIVE%"
set "CLOUDXR_JS_SAMPLES_REPO=https://github.com/NVIDIA/cloudxr-js-samples.git"
set "CLOUDXR_JS_SAMPLES_DIR=%CLOUDXR_DIR%\cloudxr-js-samples"
set "CLOUDXR_JS_SAMPLE_DIR=%CLOUDXR_JS_SAMPLES_DIR%\react"
set "MIN_NODE_VERSION=20.19.0"
set "CLOUDXR_SDK_DIR="
set "CLOUDXR_SDK_INCLUDE_DIR="
set "CLOUDXR_SDK_LIB_DIR="
set "CLOUDXR_JS_PACKAGE="

REM Parse arguments
:parse_args
if "%~1"=="" goto done_parsing

if "%~1"=="--clean" (
    echo Cleaning build directory (keeping CloudXR archives^)...
    if exist build (
        REM Stash any cached CloudXR archives outside build\, wipe build\, then
        REM restore the archives so the next build does not re-download them.
        set "_CLEAN_STASH=%TEMP%\cxr-clean-stash-%RANDOM%-%RANDOM%"
        if exist "!_CLEAN_STASH!" rmdir /s /q "!_CLEAN_STASH!"
        mkdir "!_CLEAN_STASH!" 2>nul
        if exist build\cloudxr (
            move "build\cloudxr\CloudXR-*-sdk.tar.gz" "!_CLEAN_STASH!\" >nul 2>&1
            move "build\cloudxr\CloudXR-*-sdk.zip" "!_CLEAN_STASH!\" >nul 2>&1
            move "build\cloudxr\nvidia-cloudxr-*.tgz" "!_CLEAN_STASH!\" >nul 2>&1
        )
        rmdir /s /q build
        dir /b /a-d "!_CLEAN_STASH!\*" >nul 2>&1
        if not errorlevel 1 (
            mkdir build\cloudxr
            move "!_CLEAN_STASH!\*" "build\cloudxr\" >nul 2>&1
        )
        if exist "!_CLEAN_STASH!" rmdir /s /q "!_CLEAN_STASH!"
    )
    echo Clean complete (CloudXR archives in build\cloudxr\ preserved^)
    echo   To wipe everything including archives, run: rmdir /s /q build ^&^& build.bat
    exit /b 0
)

if "%~1"=="--lovr-repo" (
    if "%~2"=="" (
        echo ERROR: Missing value for --lovr-repo
        exit /b 1
    )
    set "NEXT_ARG=%~2"
    if "!NEXT_ARG:~0,1!"=="-" (
        echo ERROR: Missing value for --lovr-repo
        exit /b 1
    )
    set "LOVR_REPO=%~2"
    shift
    shift
    goto parse_args
)

if "%~1"=="--lovr-branch" (
    if "%~2"=="" (
        echo ERROR: Missing value for --lovr-branch
        exit /b 1
    )
    set "NEXT_ARG=%~2"
    if "!NEXT_ARG:~0,1!"=="-" (
        echo ERROR: Missing value for --lovr-branch
        exit /b 1
    )
    set "LOVR_BRANCH=%~2"
    set "LOVR_COMMIT="
    shift
    shift
    goto parse_args
)

if "%~1"=="--lovr-commit" (
    if "%~2"=="" (
        echo ERROR: Missing value for --lovr-commit
        exit /b 1
    )
    set "NEXT_ARG=%~2"
    if "!NEXT_ARG:~0,1!"=="-" (
        echo ERROR: Missing value for --lovr-commit
        exit /b 1
    )
    set "LOVR_COMMIT=%~2"
    set "LOVR_BRANCH="
    shift
    shift
    goto parse_args
)

REM Accept --lovr-repo=URL / --lovr-branch=NAME / --lovr-commit=SHA forms.
set "CURRENT_ARG=%~1"
if /i "!CURRENT_ARG:~0,12!"=="--lovr-repo=" (
    set "LOVR_REPO=!CURRENT_ARG:~12!"
    if "!LOVR_REPO!"=="" (
        echo ERROR: Missing value for --lovr-repo
        exit /b 1
    )
    if "!LOVR_REPO:~0,1!"=="-" (
        echo ERROR: Missing value for --lovr-repo
        exit /b 1
    )
    shift
    goto parse_args
)
if /i "!CURRENT_ARG:~0,14!"=="--lovr-branch=" (
    set "LOVR_BRANCH=!CURRENT_ARG:~14!"
    if "!LOVR_BRANCH!"=="" (
        echo ERROR: Missing value for --lovr-branch
        exit /b 1
    )
    if "!LOVR_BRANCH:~0,1!"=="-" (
        echo ERROR: Missing value for --lovr-branch
        exit /b 1
    )
    set "LOVR_COMMIT="
    shift
    goto parse_args
)
if /i "!CURRENT_ARG:~0,14!"=="--lovr-commit=" (
    set "LOVR_COMMIT=!CURRENT_ARG:~14!"
    if "!LOVR_COMMIT!"=="" (
        echo ERROR: Missing value for --lovr-commit
        exit /b 1
    )
    if "!LOVR_COMMIT:~0,1!"=="-" (
        echo ERROR: Missing value for --lovr-commit
        exit /b 1
    )
    set "LOVR_BRANCH="
    shift
    goto parse_args
)

if "%~1"=="--without-cloudxrjs" (
    set "WITH_CLOUDXRJS=0"
    shift
    goto parse_args
)

if "%~1"=="Debug" (
    set "BUILD_TYPE=Debug"
    shift
    goto parse_args
)

if "%~1"=="Release" (
    set "BUILD_TYPE=Release"
    shift
    goto parse_args
)

if "%~1"=="RelWithDebInfo" (
    set "BUILD_TYPE=RelWithDebInfo"
    shift
    goto parse_args
)

if "%~1"=="MinSizeRel" (
    set "BUILD_TYPE=MinSizeRel"
    shift
    goto parse_args
)

REM Anything we don't recognize is forwarded to cmake (e.g. -DFOO=bar).
set "CMAKE_EXTRA_ARGS=!CMAKE_EXTRA_ARGS! %1"
shift
goto parse_args

:done_parsing

echo ========================================
echo CloudXR LOVR Build Script
echo ========================================
echo LOVR Repository: %LOVR_REPO%
if not "%LOVR_BRANCH%"=="" (
    echo LOVR Branch: %LOVR_BRANCH%
) else if not "%LOVR_COMMIT%"=="" (
    echo LOVR Commit: %LOVR_COMMIT%
) else (
    echo LOVR Ref: default branch
)
echo Build Type: %BUILD_TYPE%
if "%WITH_CLOUDXRJS%"=="1" (
    echo CloudXR.js Setup: enabled ^(pass --without-cloudxrjs to skip^)
) else (
    echo CloudXR.js Setup: disabled
)
echo ========================================

REM =============================================================================
REM Helper functions
REM =============================================================================
goto :skip_helper_functions

:download_file
    set "DOWNLOAD_URL=%~1"
    set "DOWNLOAD_OUTPUT=%~2"
    set "DOWNLOAD_LABEL=%~3"

    if exist "%DOWNLOAD_OUTPUT%" (
        echo Found %DOWNLOAD_LABEL%: %DOWNLOAD_OUTPUT%
        exit /b 0
    )

    where curl >nul 2>&1
    if errorlevel 1 (
        echo ERROR: curl is required to download %DOWNLOAD_LABEL%
        echo Download it manually from:
        echo   %DOWNLOAD_URL%
        echo Save it as:
        echo   %DOWNLOAD_OUTPUT%
        exit /b 1
    )

    for %%D in ("%DOWNLOAD_OUTPUT%") do (
        if not exist "%%~dpD" mkdir "%%~dpD"
    )

    echo Downloading %DOWNLOAD_LABEL%...
    curl -fL "%DOWNLOAD_URL%" -o "%DOWNLOAD_OUTPUT%"
    if errorlevel 1 (
        echo ERROR: Failed to download %DOWNLOAD_LABEL%
        exit /b 1
    )

    if not exist "%DOWNLOAD_OUTPUT%" (
        echo ERROR: Downloaded %DOWNLOAD_LABEL% was not created: %DOWNLOAD_OUTPUT%
        exit /b 1
    )

    for %%A in ("%DOWNLOAD_OUTPUT%") do (
        if %%~zA LEQ 0 (
            echo ERROR: Downloaded %DOWNLOAD_LABEL% is empty: %DOWNLOAD_OUTPUT%
            exit /b 1
        )
    )

    echo Downloaded %DOWNLOAD_LABEL%: %DOWNLOAD_OUTPUT%
    exit /b 0

:download_cloudxr_runtime_sdk
    call :download_file "%DEFAULT_CLOUDXR_RUNTIME_URL%" "%CLOUDXR_DIR%\%DEFAULT_CLOUDXR_RUNTIME_ARCHIVE%" "CloudXR Runtime SDK"
    exit /b !errorlevel!

:stage_cloudxr_sdk_files
    set "SDK_DIR=%~1"

    if not exist "!SDK_DIR!\include\cxrServiceAPI.h" (
        echo ERROR: CloudXR SDK headers not found in !SDK_DIR!\include
        exit /b 1
    )

    dir /b "!SDK_DIR!\*.dll" >nul 2>&1
    if errorlevel 1 (
        echo ERROR: CloudXR SDK libraries not found in !SDK_DIR!
        exit /b 1
    )

    set "CLOUDXR_SDK_DIR=!SDK_DIR!"
    set "CLOUDXR_SDK_INCLUDE_DIR=!SDK_DIR!\include"
    set "CLOUDXR_SDK_LIB_DIR=!SDK_DIR!"
    exit /b 0

:find_cloudxr_sdk
    for /d %%D in (%CLOUDXR_DIR%\CloudXR-%CLOUDXR_RUNTIME_VERSION%-Win64-sdk) do (
        if exist "%%D" (
            call :stage_cloudxr_sdk_files "%%D"
            if not errorlevel 1 exit /b 0
        )
    )

    for /d %%D in (%CLOUDXR_DIR%\CloudXR-*-Win64-sdk) do (
        if exist "%%D" (
            call :stage_cloudxr_sdk_files "%%D"
            if not errorlevel 1 exit /b 0
        )
    )
    exit /b 1

:extract_cloudxr_sdk
    echo CloudXR SDK not found in build directory. Searching for SDK archive...

    set "SDK_ARCHIVE=%CLOUDXR_DIR%\%DEFAULT_CLOUDXR_RUNTIME_ARCHIVE%"
    if not exist "!SDK_ARCHIVE!" (
        set "SDK_ARCHIVE="
        for %%F in (%CLOUDXR_DIR%\CloudXR-*-Win64-sdk.zip) do (
            if exist "%%F" (
                set "SDK_ARCHIVE=%%F"
                goto sdk_archive_found
            )
        )
    )

:sdk_archive_found
    if "!SDK_ARCHIVE!"=="" (
        echo CloudXR SDK archive not found locally. Downloading CloudXR Runtime SDK...
        call :download_cloudxr_runtime_sdk
        if errorlevel 1 (
            echo You can also download CloudXR SDK from:
            echo    https://catalog.ngc.nvidia.com/orgs/nvidia/collections/cloudxr-sdk
            echo Place the CloudXR-*-Win64-sdk.zip file in build\cloudxr\.
            exit /b 1
        )
        set "SDK_ARCHIVE=%CLOUDXR_DIR%\%DEFAULT_CLOUDXR_RUNTIME_ARCHIVE%"
    )

    echo Found SDK archive: !SDK_ARCHIVE!
    echo Extracting SDK into %CLOUDXR_DIR%...

    for %%A in ("!SDK_ARCHIVE!") do set "SDK_DIR_NAME=%%~nA"
    set "SDK_EXTRACT_DIR=%CLOUDXR_DIR%\!SDK_DIR_NAME!"
    set "SDK_EXTRACT_TMP=%CLOUDXR_DIR%\.extract-tmp"

    REM Extract into a temp dir, then flatten if the archive wraps everything
    REM in a single top-level directory (matches build.sh --strip-components=1).
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "$ErrorActionPreference = 'Stop';" ^
        "$tmp = '!SDK_EXTRACT_TMP!';" ^
        "$final = '!SDK_EXTRACT_DIR!';" ^
        "if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }" ^
        "if (Test-Path $final) { Remove-Item -Recurse -Force $final }" ^
        "New-Item -ItemType Directory -Force -Path $tmp | Out-Null;" ^
        "Expand-Archive -Path '!SDK_ARCHIVE!' -DestinationPath $tmp -Force;" ^
        "$items = @(Get-ChildItem -Force $tmp);" ^
        "if ($items.Count -eq 1 -and $items[0].PSIsContainer) {" ^
        "    Move-Item -Path $items[0].FullName -Destination $final;" ^
        "    Remove-Item -Recurse -Force $tmp" ^
        "} else {" ^
        "    Move-Item -Path $tmp -Destination $final" ^
        "}"

    if errorlevel 1 (
        echo ERROR: Failed to extract SDK archive
        if exist "!SDK_EXTRACT_TMP!" rmdir /s /q "!SDK_EXTRACT_TMP!"
        exit /b 1
    )

    call :stage_cloudxr_sdk_files "!SDK_EXTRACT_DIR!"
    if errorlevel 1 exit /b 1

    echo CloudXR SDK staged in build directory:
    echo   Headers: !CLOUDXR_SDK_INCLUDE_DIR!
    echo   Libraries: !CLOUDXR_SDK_LIB_DIR!
    exit /b 0

:ensure_cloudxr_sdk
    call :find_cloudxr_sdk
    if not errorlevel 1 (
        echo Reusing existing CloudXR SDK at: !CLOUDXR_SDK_DIR!
        echo   To switch to a new SDK, place the archive in %CLOUDXR_DIR%\ then run `build.bat --clean ^&^& build.bat`.
        echo   `--clean` wipes the build output but keeps cached archives in %CLOUDXR_DIR%\.
        exit /b 0
    )
    call :extract_cloudxr_sdk
    exit /b !errorlevel!

:node_version_at_least
    set "NODE_VERSION_VALUE=%~1"
    for /f "tokens=1-3 delims=." %%A in ("!NODE_VERSION_VALUE!") do (
        set "NODE_MAJOR=%%A"
        set "NODE_MINOR=%%B"
        set "NODE_PATCH=%%C"
    )
    for /f "tokens=1-3 delims=." %%A in ("%MIN_NODE_VERSION%") do (
        set "MIN_NODE_MAJOR=%%A"
        set "MIN_NODE_MINOR=%%B"
        set "MIN_NODE_PATCH=%%C"
    )
    for /f "tokens=1 delims=-+" %%A in ("!NODE_PATCH!") do set "NODE_PATCH=%%A"
    if "!NODE_MAJOR!"=="" set "NODE_MAJOR=0"
    if "!NODE_MINOR!"=="" set "NODE_MINOR=0"
    if "!NODE_PATCH!"=="" set "NODE_PATCH=0"

    if !NODE_MAJOR! GTR !MIN_NODE_MAJOR! exit /b 0
    if !NODE_MAJOR! LSS !MIN_NODE_MAJOR! exit /b 1
    if !NODE_MINOR! GTR !MIN_NODE_MINOR! exit /b 0
    if !NODE_MINOR! LSS !MIN_NODE_MINOR! exit /b 1
    if !NODE_PATCH! GEQ !MIN_NODE_PATCH! exit /b 0
    exit /b 1

:prompt_node_install
    echo %~1
    echo CloudXR.js setup requires Node.js v%MIN_NODE_VERSION% or later with npm.
    set "INSTALL_NODE="
    set /p INSTALL_NODE=Install Node.js v%MIN_NODE_VERSION% or later now? [y/N]
    if /i "!INSTALL_NODE!"=="Y" (
        where winget >nul 2>&1
        if errorlevel 1 (
            echo Automatic Node.js install requires winget on Windows. Install Node.js v%MIN_NODE_VERSION% or later from https://nodejs.org/, then rerun build.bat ^(or pass --without-cloudxrjs to skip^).
        ) else (
            echo Installing Node.js LTS with winget...
            winget install --id OpenJS.NodeJS.LTS -e
            echo If this install succeeded, open a new terminal and rerun build.bat so PATH is refreshed.
        )
    ) else (
        echo Skipping CloudXR.js setup.
    )
    exit /b 1

:check_node_version
    where node >nul 2>&1
    if errorlevel 1 (
        call :prompt_node_install "Node.js was not found."
        exit /b 1
    )

    set "NODE_VERSION="
    for /f "tokens=*" %%V in ('node -v 2^>nul') do set "NODE_VERSION=%%V"
    set "NODE_VERSION=!NODE_VERSION:v=!"
    if "!NODE_VERSION!"=="" (
        call :prompt_node_install "Node.js version could not be read."
        exit /b 1
    )

    call :node_version_at_least "!NODE_VERSION!"
    if errorlevel 1 (
        call :prompt_node_install "Node.js v!NODE_VERSION! is installed, but v%MIN_NODE_VERSION% or later is required."
        exit /b 1
    )

    where npm >nul 2>&1
    if errorlevel 1 (
        call :prompt_node_install "npm was not found."
        exit /b 1
    )

    echo Node.js v!NODE_VERSION! meets CloudXR.js requirement
    exit /b 0

:ensure_cloudxr_js_package
    set "CLOUDXR_JS_PACKAGE="
    set "EXPECTED_CLOUDXR_JS_PACKAGE=%CLOUDXR_DIR%\%DEFAULT_CLOUDXR_JS_ARCHIVE%"
    if exist "!EXPECTED_CLOUDXR_JS_PACKAGE!" (
        set "CLOUDXR_JS_PACKAGE=!EXPECTED_CLOUDXR_JS_PACKAGE!"
        echo Found CloudXR.js package: !CLOUDXR_JS_PACKAGE!
        exit /b 0
    )

    for %%F in ("%CLOUDXR_DIR%\nvidia-cloudxr-*.tgz") do (
        if exist "%%F" (
            set "CLOUDXR_JS_PACKAGE=%%~F"
            echo Found CloudXR.js package: !CLOUDXR_JS_PACKAGE!
            exit /b 0
        )
    )
    call :download_file "%DEFAULT_CLOUDXR_JS_URL%" "%CLOUDXR_DIR%\%DEFAULT_CLOUDXR_JS_ARCHIVE%" "CloudXR.js package"
    if errorlevel 1 exit /b 1
    set "CLOUDXR_JS_PACKAGE=%CLOUDXR_DIR%\%DEFAULT_CLOUDXR_JS_ARCHIVE%"
    exit /b 0

:setup_cloudxr_js
    echo.
    echo Setting up CloudXR.js local development sample...

    if not exist build mkdir build
    call :ensure_cloudxr_js_package
    if errorlevel 1 exit /b 1

    call :check_node_version
    if errorlevel 1 exit /b 1

    if not exist "%CLOUDXR_JS_SAMPLE_DIR%\package.json" (
        if exist "%CLOUDXR_JS_SAMPLES_DIR%" (
            echo ERROR: %CLOUDXR_JS_SAMPLES_DIR% exists but the React sample was not found
            echo Remove it and rerun: rmdir /s /q "%CLOUDXR_JS_SAMPLES_DIR%" ^&^& build.bat
            exit /b 1
        )

        echo Cloning CloudXR.js samples...
        git clone --depth 1 "%CLOUDXR_JS_SAMPLES_REPO%" "%CLOUDXR_JS_SAMPLES_DIR%"
        if errorlevel 1 (
            echo ERROR: Failed to clone CloudXR.js samples
            if exist "%CLOUDXR_JS_SAMPLES_DIR%" rmdir /s /q "%CLOUDXR_JS_SAMPLES_DIR%"
            exit /b 1
        )
    ) else (
        echo Using existing CloudXR.js samples in %CLOUDXR_JS_SAMPLES_DIR%
    )

    echo CloudXR.js React sample directory: %CLOUDXR_JS_SAMPLE_DIR%
    echo Installing CloudXR.js package from !CLOUDXR_JS_PACKAGE!...
    for %%A in ("!CLOUDXR_JS_PACKAGE!") do set "CLOUDXR_JS_PACKAGE_FILE=%%~nxA"
    pushd "%CLOUDXR_JS_SAMPLE_DIR%"
    REM npm is npm.cmd on Windows; invoking a batch file from this batch
    REM file without `call` clobbers our instruction pointer, so subsequent
    REM label lookups (e.g. returning from :setup_cloudxr_js) fail with
    REM "The system cannot find the batch label specified". Always use
    REM `call npm ...` here.
    call npm --registry https://registry.npmjs.org/ install "..\..\!CLOUDXR_JS_PACKAGE_FILE!"
    if errorlevel 1 (
        popd
        echo ERROR: CloudXR.js package install failed
        exit /b 1
    )

    echo Installing CloudXR.js sample dependencies...
    call npm --registry https://registry.npmjs.org/ install
    if errorlevel 1 (
        popd
        echo ERROR: CloudXR.js dependency install failed
        exit /b 1
    )

    echo Building CloudXR.js React sample...
    call npm run build
    if errorlevel 1 (
        popd
        echo ERROR: CloudXR.js sample build failed
        exit /b 1
    )
    popd

    echo CloudXR.js setup complete
    exit /b 0

:skip_helper_functions

REM =============================================================================
REM Verify CloudXR SDK
REM =============================================================================

echo.
echo Checking CloudXR SDK installation...
call :ensure_cloudxr_sdk
if errorlevel 1 exit /b 1

REM =============================================================================
REM Fetch LOVR if not present
REM =============================================================================

if not exist "build\src" (
    echo.
    echo Fetching LOVR...
    if not exist build mkdir build

    REM Pick clone args based on which ref was requested. For an arbitrary
    REM commit we need the full history, so we clone first and then check out
    REM + init submodules in a second step.
    if not "!LOVR_BRANCH!"=="" (
        set "CLONE_ARGS=--depth 1 --branch "!LOVR_BRANCH!" --recurse-submodules"
        set "REF_LABEL=branch !LOVR_BRANCH!"
    ) else if not "!LOVR_COMMIT!"=="" (
        set "CLONE_ARGS="
        set "REF_LABEL=commit !LOVR_COMMIT!"
    ) else (
        set "CLONE_ARGS=--recurse-submodules"
        set "REF_LABEL=default branch"
    )

    echo Cloning from: !LOVR_REPO! ^(!REF_LABEL!^)
    git clone !CLONE_ARGS! "!LOVR_REPO!" build\src
    if errorlevel 1 (
        echo ERROR: Failed to clone LOVR
        exit /b 1
    )

    if not "!LOVR_COMMIT!"=="" (
        echo Checking out commit !LOVR_COMMIT!...
        pushd build\src
        git checkout !LOVR_COMMIT!
        if errorlevel 1 (
            popd
            echo ERROR: Failed to checkout commit !LOVR_COMMIT!
            exit /b 1
        )
        git submodule update --init --recursive
        if errorlevel 1 (
            popd
            echo ERROR: Failed to initialize submodules
            exit /b 1
        )
        popd
    )
    echo LOVR ready in build\src\ ^(with submodules^)
) else (
    echo.
    echo Using existing LOVR in build\src\
    pushd build\src
    git submodule update --init --recursive
    popd
    echo Submodules updated
)

REM =============================================================================
REM Copy plugin into LOVR
REM =============================================================================

echo.
echo Installing CloudXR plugin...
if exist build\src\plugins\nvidia rmdir /s /q build\src\plugins\nvidia
xcopy plugins\nvidia build\src\plugins\nvidia\ /E /I /Y >nul
if errorlevel 1 (
    echo ERROR: Failed to copy CloudXR plugin to build\src\plugins\nvidia\
    exit /b 1
)
echo Plugin copied to build\src\plugins\nvidia\

REM =============================================================================
REM Configure CMake
REM =============================================================================

echo.
echo Configuring CMake (%BUILD_TYPE% build^)...

REM CMAKE_ENABLE_EXPORTS=ON - Enable symbol exports from the LOVR executable
REM LOVR_BUILD_WITH_SYMBOLS=ON - Export all symbols (not just the subset normally marked for export)
REM LOVR_USE_STEAM_AUDIO=OFF - Avoid Steam Audio's vendored mysofa/zlib MSVC build issue
REM CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS=OFF - Avoid auto-exporting third-party DLL targets
cmake -B build -S build\src -DCMAKE_BUILD_TYPE=%BUILD_TYPE% -DCMAKE_ENABLE_EXPORTS=ON -DLOVR_BUILD_WITH_SYMBOLS=ON -DLOVR_USE_STEAM_AUDIO=OFF -DCMAKE_WINDOWS_EXPORT_ALL_SYMBOLS=OFF "-DCLOUDXR_INCLUDE_PATH=%CD%\!CLOUDXR_SDK_INCLUDE_DIR!" "-DCLOUDXR_LIB_PATH=%CD%\!CLOUDXR_SDK_LIB_DIR!" %CMAKE_EXTRA_ARGS%

if errorlevel 1 (
    echo ERROR: CMake configuration failed
    exit /b 1
)

echo Configuration complete

REM =============================================================================
REM Build
REM =============================================================================

echo.
echo Building LOVR with CloudXR plugin...
echo This may take a few minutes on first build...

cmake --build build --config %BUILD_TYPE%

if errorlevel 1 (
    echo ERROR: Build failed
    exit /b 1
)

if "%WITH_CLOUDXRJS%"=="1" (
    call :setup_cloudxr_js
    if errorlevel 1 exit /b 1
)
REM =============================================================================
REM Success
REM =============================================================================

echo.
echo ========================================
echo Build complete!
echo ========================================
echo.
echo Run the example:
echo   run.bat                                      ^(Apple Vision Pro - default^)
echo   run.bat --device-profile=auto-webrtc         ^(via CloudXR.js^)
echo.
echo See README.md for advanced options and other device profiles.
echo.
