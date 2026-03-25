@echo off
REM SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
REM SPDX-License-Identifier: MIT
REM
REM =============================================================================
REM CloudXR LOVR Build Script for Windows
REM =============================================================================
REM Usage:
REM   build.bat                                      - Build with default LOVR
REM   build.bat Release                              - Build in Release mode
REM   build.bat clean                                - Clean build directory
REM   build.bat cleanall                             - Clean build and src
REM   build.bat --lovr-repo <url> --lovr-branch <branch>  - Use custom LOVR branch
REM   build.bat --lovr-repo <url> --lovr-commit <commit>  - Use custom LOVR commit
REM =============================================================================

setlocal enabledelayedexpansion

REM Default values
set BUILD_TYPE=Debug
set LOVR_REPO=https://github.com/bjornbytes/lovr.git
set LOVR_COMMIT=7d47902f594334b9709bfd819cd20514addefbaf
set LOVR_BRANCH=
set CMAKE_EXTRA_ARGS=

REM Parse arguments
:parse_args
if "%~1"=="" goto done_parsing

if "%~1"=="clean" (
    echo Cleaning build directory (keeping source^)...
    for /d %%D in (build\*) do (
        if /i not "%%~nxD"=="src" rmdir /s /q "%%D"
    )
    for %%F in (build\*) do (
        if not "%%~aF"=="d*" del /q "%%F"
    )
    echo Clean complete (build\src preserved^)
    echo.
    echo Run build.bat to rebuild
    exit /b 0
)

if "%~1"=="cleanall" (
    echo Cleaning entire build directory...
    if exist build rmdir /s /q build
    echo Clean complete
    echo.
    echo Run build.bat to rebuild
    exit /b 0
)

if "%~1"=="--lovr-repo" (
    set LOVR_REPO=%~2
    shift
    shift
    goto parse_args
)

if "%~1"=="--lovr-branch" (
    set LOVR_BRANCH=%~2
    set LOVR_COMMIT=
    shift
    shift
    goto parse_args
)

if "%~1"=="--lovr-commit" (
    set LOVR_COMMIT=%~2
    set LOVR_BRANCH=
    shift
    shift
    goto parse_args
)

if "%~1"=="Debug" (
    set BUILD_TYPE=Debug
    shift
    goto parse_args
)

if "%~1"=="Release" (
    set BUILD_TYPE=Release
    shift
    goto parse_args
)

if "%~1"=="RelWithDebInfo" (
    set BUILD_TYPE=RelWithDebInfo
    shift
    goto parse_args
)

if "%~1"=="MinSizeRel" (
    set BUILD_TYPE=MinSizeRel
    shift
    goto parse_args
)

REM Collect other arguments
set CMAKE_EXTRA_ARGS=!CMAKE_EXTRA_ARGS! %~1
shift
goto parse_args

:done_parsing

echo ========================================
echo CloudXR LOVR Build Script
echo ========================================
echo LOVR Repository: %LOVR_REPO%
if not "%LOVR_BRANCH%"=="" (
    echo LOVR Branch: %LOVR_BRANCH%
) else (
    echo LOVR Commit: %LOVR_COMMIT%
)
echo Build Type: %BUILD_TYPE%
echo ========================================

REM =============================================================================
REM Helper function to extract and setup CloudXR SDK
REM =============================================================================
goto :skip_extract_cloudxr_sdk

:extract_cloudxr_sdk
    echo CloudXR SDK not found in plugins directory. Searching for SDK archive...
    
    REM Find CloudXR SDK archive
    set SDK_ARCHIVE=
    for %%F in (CloudXR-*-Win64-sdk.zip) do (
        set SDK_ARCHIVE=%%F
        goto found_archive
    )
    
    :found_archive
    if "%SDK_ARCHIVE%"=="" (
        echo ERROR: CloudXR SDK archive not found!
        echo Please download CloudXR SDK from:
        echo    https://catalog.ngc.nvidia.com/orgs/nvidia/collections/cloudxr-sdk
        echo.
        echo Place the CloudXR-*-Win64-sdk.zip file in the project root
        exit /b 1
    )
    
    echo Found SDK archive: %SDK_ARCHIVE%
    echo Extracting SDK...
    
    REM Determine extraction directory (remove .zip extension)
    set SDK_DIR_NAME=%SDK_ARCHIVE:~0,-4%
    set SDK_EXTRACT_DIR=build\!SDK_DIR_NAME!
    
    REM Extract the archive to a specific directory without .zip in the name
    powershell -Command "Expand-Archive -Path '%SDK_ARCHIVE%' -DestinationPath '!SDK_EXTRACT_DIR!' -Force"
    
    if errorlevel 1 (
        echo ERROR: Failed to extract SDK archive
        exit /b 1
    )
    
    REM Verify the include directory exists at the top level
    set SDK_DIR=!SDK_EXTRACT_DIR!
    if not exist "!SDK_DIR!\include" (
        echo ERROR: Include directory not found in extracted SDK at !SDK_DIR!
        exit /b 1
    )
    
    echo SDK extracted to: !SDK_DIR!
    echo Copying SDK files to plugin directories...
    
    REM Create target directories if they don't exist
    if not exist "plugins\nvidia\include" mkdir "plugins\nvidia\include"
    if not exist "plugins\nvidia\lib\windows-x86_64" mkdir "plugins\nvidia\lib\windows-x86_64"
    
    REM Copy include directory contents
    if exist "!SDK_DIR!\include" (
        echo   Copying headers...
        xcopy "!SDK_DIR!\include\*" "plugins\nvidia\include\" /E /I /Y >nul
        echo   Headers copied to plugins\nvidia\include\
    ) else (
        echo ERROR: Include directory not found in SDK
        exit /b 1
    )
    
    REM Copy everything else (excluding include directory) to lib\windows-x86_64
    echo   Copying libraries and other files...
    for /d %%D in (!SDK_DIR!\*) do (
        if /i not "%%~nxD"=="include" (
            xcopy "%%D" "plugins\nvidia\lib\windows-x86_64\%%~nxD\" /E /I /Y >nul
        )
    )
    for %%F in (!SDK_DIR!\*) do (
        if not "%%~aF"=="d*" (
            copy "%%F" "plugins\nvidia\lib\windows-x86_64\" >nul
        )
    )
    echo   Libraries copied to plugins\nvidia\lib\windows-x86_64\
    
    echo CloudXR SDK setup complete!
    exit /b 0

:skip_extract_cloudxr_sdk

REM =============================================================================
REM Verify CloudXR SDK
REM =============================================================================

echo.
echo Checking CloudXR SDK installation...

if not exist "plugins\nvidia\include\cxrServiceAPI.h" (
    call :extract_cloudxr_sdk
    if errorlevel 1 exit /b 1
)

echo CloudXR SDK headers found

REM Check for DLLs (should have been extracted with headers)
dir /b "plugins\nvidia\lib\windows-x86_64\*.dll" >nul 2>&1
if errorlevel 1 (
    call :extract_cloudxr_sdk
    if errorlevel 1 exit /b 1
)

echo CloudXR SDK libraries found

REM =============================================================================
REM Fetch LOVR if not present
REM =============================================================================

if not exist "build\src" (
    echo.
    echo Fetching LOVR...
    if not exist build mkdir build
    if not "!LOVR_BRANCH!"=="" (
        echo Cloning from: %LOVR_REPO% (branch !LOVR_BRANCH!^)
        git clone --depth 1 --branch "!LOVR_BRANCH!" --recurse-submodules %LOVR_REPO% build\src

        if errorlevel 1 (
            echo ERROR: Failed to clone LOVR
            exit /b 1
        )

        echo LOVR cloned successfully with submodules
    ) else (
        echo Cloning from: %LOVR_REPO% (commit %LOVR_COMMIT%^)
        git clone %LOVR_REPO% build\src

        if errorlevel 1 (
            echo ERROR: Failed to clone LOVR
            exit /b 1
        )

        echo Checking out commit %LOVR_COMMIT%...
        cd build\src
        git checkout %LOVR_COMMIT%

        if errorlevel 1 (
            echo ERROR: Failed to checkout commit %LOVR_COMMIT%
            cd ..\..
            exit /b 1
        )

        git submodule update --init --recursive

        if errorlevel 1 (
            echo ERROR: Failed to initialize submodules
            cd ..\..
            exit /b 1
        )

        cd ..\..
        echo LOVR cloned and checked out successfully with submodules
    )
) else (
    echo.
    echo Using existing LOVR in build\src\
    echo Updating submodules...
    cd build\src
    git submodule update --init --recursive
    cd ..\..
    echo Submodules updated
)

REM =============================================================================
REM Copy plugin into LOVR
REM =============================================================================

echo.
echo Installing CloudXR plugin...
if exist build\src\plugins\nvidia rmdir /s /q build\src\plugins\nvidia
mklink /J build\src\plugins\nvidia plugins\nvidia
echo Plugin linked to build\src\plugins\nvidia\

REM =============================================================================
REM Configure CMake
REM =============================================================================

echo.
echo Configuring CMake (%BUILD_TYPE% build^)...

REM CMAKE_ENABLE_EXPORTS=ON - Enable symbol exports from the LOVR executable
REM LOVR_BUILD_WITH_SYMBOLS=ON - Export all symbols (not just the subset normally marked for export)
cmake -B build -S build\src -DCMAKE_BUILD_TYPE=%BUILD_TYPE% -DCMAKE_ENABLE_EXPORTS=ON -DLOVR_BUILD_WITH_SYMBOLS=ON -DCMAKE_WINDOWS_EXPORT_ALL_SYMBOLS=ON %CMAKE_EXTRA_ARGS%

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

REM =============================================================================
REM Success
REM =============================================================================

echo.
echo ========================================
echo Build Complete!
echo ========================================
echo.
echo Directory structure:
echo   build\src\           - LOVR source with CloudXR plugin
echo   build\%BUILD_TYPE%\  - Build output (Windows)
echo.
echo To run the CloudXR example:
echo   run.bat
echo.
echo Or manually:
echo   cd build\%BUILD_TYPE%
echo   lovr.exe ..\src\plugins\nvidia\examples\cloudxr
echo.
echo For Quest 3 (Early Access^):
echo   run.bat --webrtc
echo.

