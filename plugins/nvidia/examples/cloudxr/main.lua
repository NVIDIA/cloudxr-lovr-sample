-- SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
-- SPDX-License-Identifier: MIT

-- Models are provided by immersive-web under the MIT license
-- https://github.com/immersive-web/webxr-input-profiles/blob/main/packages/assets/LICENSE.md
-- https://github.com/immersive-web/webxr-input-profiles/tree/main/packages/assets/profiles/meta-quest-touch-plus

print("NVIDIA CloudXR Plugin Example")

-- Import our custom modules
-- These handle different aspects of the CloudXR integration
local CloudXRManager = require('cloudxr_manager')  -- Manages CloudXR runtime and opaque data channels
local HeadsetManager = require('headset_manager')  -- Manages OpenXR headset initialization
local Renderer = require('renderer')               -- Handles rendering of VR content and data
local AudioManager = require('audio_manager')      -- Manages audio playback triggered by hand gestures

-- Parse command line arguments to check for special flags
-- This allows users to modify behavior without changing code
local function parseArgs()
    local args = {}
    
    -- Look for command line flags (arguments starting with --)
    -- This is useful for development and testing different configurations
    for i = 1, #arg do
        local argStr = arg[i]
        if argStr:sub(1, 2) == "--" and not argStr:find("=") then
            -- Extract the flag name (remove -- prefix)
            local flagName = argStr:sub(3)
            args[flagName] = true
            print("Flag enabled:", flagName)
        end
    end
    
    return args
end

-- LÖVR load function - called once when the application starts
-- This is where we initialize all our modules in the correct order
function lovr.load(args)
    print("Loading CloudXR manager...")    
    
    -- Parse command line arguments first
    local parsedArgs = parseArgs()
    
    -- Initialize the CloudXR plugin (loads the nvidia.dll/nvidia.so library)
    if not CloudXRManager.init(parsedArgs) then
        print("Failed to initialize CloudXR")
        return
    end
    
    -- Initialize CloudXR runtime service (unless using system runtime)
    -- This must happen BEFORE OpenXR initialization
    if not parsedArgs.use_system_runtime then       
        if CloudXRManager.initRuntime(parsedArgs) then
            print("CloudXR Runtime initialized successfully")
        else
            print("Failed to initialize CloudXR Runtime")
        end
    else
        print("Skipping CloudXR Runtime initialization (--use_system_runtime flag detected)")
    end
    
    -- Initialize OpenXR headset and graphics
    -- This creates the OpenXR instance and starts VR rendering
    if not HeadsetManager.init() then
        print("Failed to initialize headset")
        return
    end

    -- Initialize opaque data channels AFTER OpenXR is ready
    -- This enables custom communication between app and headset
    if not CloudXRManager.initOpaqueDataChannel() then
        print("Failed to initialize Opaque Data Channel")
        return
    end
    
    -- Initialize audio manager for hand gesture-triggered audio playback
    if not AudioManager.init() then
        print("Failed to initialize Audio Manager")
        -- Continue anyway, audio is not critical
    end
    
    print("Application initialized successfully")
end

-- LÖVR quit function - called when the application is shutting down
-- Clean up resources in reverse order of initialization
function lovr.quit()
    print("Cleaning up application...")
    
    -- Clean up audio manager
    if AudioManager then
        AudioManager.cleanup()
    end
    
    -- Clean up headset and OpenXR resources first
    HeadsetManager.cleanup()
    
    -- Clean up CloudXR resources (runtime service and opaque data channels)
    if CloudXRManager then
        CloudXRManager.destroy()
    end
    
    print("Cleanup complete")
end 

-- LÖVR draw function - called every frame to render the VR scene
-- This is where we draw all the VR content that gets streamed to the headset
function lovr.draw(pass)
    local lastReceivedData = nil
    
    -- Get any data received from the headset via opaque data channels
    -- This could be custom sensor data, user input, or other information
    if CloudXRManager then
        lastReceivedData = CloudXRManager.getLastReceivedData()
        -- Render any opaque data (like hand tracking data) if available
        Renderer.drawOpaqueData(pass, lastReceivedData)
    end
    
    -- Get controller models for rendering
    local models = HeadsetManager.getModels()
    
    -- Draw hand joints and controller models in the VR space
    Renderer.drawHandJoints(pass, lastReceivedData)
    Renderer.drawControllers(pass, models)
  
    -- Reset color to white for subsequent rendering
    pass:setColor(1, 1, 1, 1)
end

-- LÖVR update function - called every frame for game logic and updates
-- This is where we handle input, update state, and process opaque data
function lovr.update(dt)
    -- Check for Enter key press to exit the application
    if lovr.system and lovr.system.isKeyDown('return') then
        print("Enter key pressed - exiting application")
        lovr.event.quit()
        return
    end

    -- Only update if the headset is active and tracking
    if not HeadsetManager.isActive() then
        return
    end
    
    -- Update CloudXR opaque data channels
    -- This processes any incoming data from the headset and sends outgoing data
    if CloudXRManager then
        CloudXRManager.update()
    end
    
    -- Update audio manager to check for hand gestures
    if AudioManager then
        AudioManager.update()
    end
end
