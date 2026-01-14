-- SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
-- SPDX-License-Identifier: MIT

-- LÖVR configuration function - called before the application starts
-- This is where we configure LÖVR modules and set up CloudXR integration
function lovr.conf(t)
    -- Disable default graphics module since we'll initialize it manually after CloudXR
    t.modules.graphics = false
    
    -- Disable default headset module since CloudXR replaces the standard OpenXR runtime
    -- We'll initialize the headset manually after CloudXR runtime is ready
    t.modules.headset = false

    -- Configure OpenXR settings for CloudXR integration
    t.headset.extensions = {
        -- Request the CloudXR opaque data channel extension
        -- This enables custom bidirectional communication between app and headset
        -- Workaround: Manually add null terminator to the extensions string. Can be removed once the extensions string parser is fixed.
        'XR_NVX1_opaque_data_channel\0',
    }

    -- Check if we should set the CloudXR runtime JSON path
    -- This can be disabled with --use_system_runtime flag for development
    local shouldSetRuntimeJson = true
    
    -- Parse command line arguments to check for --use_system_runtime flag
    if arg then
        for i, argument in ipairs(arg) do
            if argument == "--use_system_runtime" then
                print("Skipping setting CloudXR runtime JSON (using system runtime)")
                shouldSetRuntimeJson = false
                break
            end
        end
    end

    if shouldSetRuntimeJson then
        -- Load LÖVR modules early to access filesystem and system functions
        -- This is needed to set the XR_RUNTIME_JSON environment variable before OpenXR initialization
        
        -- Load filesystem module to get executable path
        if not lovr.filesystem then
            local loaded, result = pcall(require, 'lovr.filesystem')
            if not loaded then
                print("Failed to load lovr.filesystem")
                return false
            end
            lovr.filesystem = result
        end

        -- Load system module to set environment variables
        if not lovr.system then
            local loaded, result = pcall(require, 'lovr.system')
            if not loaded then
                print("Failed to load lovr.system")
                return false
            end
            lovr.system = result
        end

        -- Find the CloudXR runtime JSON file in the same directory as the executable
        -- This tells the OpenXR loader to use CloudXR instead of the system OpenXR runtime
        local exePath = lovr.filesystem.getExecutablePath()
        local exeDir = exePath:match("(.*[\\/])") or ""  -- Extract directory path
        local runtimeJsonPath = exeDir .. "openxr_cloudxr.json"
        
        -- Set the XR_RUNTIME_JSON environment variable
        -- This must be done BEFORE OpenXR initialization (when lovr.headset is required)
        -- The OpenXR loader reads this environment variable to know which runtime to use
        print("Executable path:", exePath)
        print("Executable directory:", exeDir)
        print("Runtime JSON path:", runtimeJsonPath)

        local f=io.open(runtimeJsonPath,"r")
        if f~=nil then
            io.close(f)
        else
            print("********************************************************")
            print("ERROR: Failed to open runtime JSON file.")
            print("CloudXR Runtime will fail to initialize.")
            print("Check the file exists and try again.")
            print("********************************************************")
            return false
        end
        
        t.headset.initproperties = {
            { name = "XR_RUNTIME_JSON", value = runtimeJsonPath },
        }
    end
end
