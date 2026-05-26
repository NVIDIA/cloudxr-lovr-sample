-- SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
-- SPDX-License-Identifier: MIT

-- CloudXR Manager Module
-- This module handles all CloudXR-related functionality including:
-- - Loading the CloudXR plugin
-- - Starting/stopping the CloudXR runtime service
-- - Managing opaque data channels for custom communication
-- - Processing data received from the headset

local CloudXRManager = {}

-- Global variables to store the CloudXR plugin and received data
local nv_cxr = nil              -- Reference to the loaded CloudXR plugin
local lastReceivedData = nil    -- Cache of the most recent data received from headset
local waitingForClientConnection = false
local clientConnectionReady = false

local DEFAULT_DEVICE_PROFILE = "apple-vision-pro"

local function getDeviceProfile(args)
    if args then
        if args["device-profile"] ~= nil then
            if type(args["device-profile"]) ~= "string" or args["device-profile"] == "" then
                return nil, "Use --device-profile=<profile> (e.g. --device-profile=apple-vision-pro)"
            end
            return args["device-profile"]
        end
    end

    return DEFAULT_DEVICE_PROFILE
end

local function shouldPollForDeviceProfile(deviceProfile)
    return type(deviceProfile) == "string" and deviceProfile:sub(1, 5) == "auto-"
end

-- Initialize the CloudXR plugin by loading the nvidia.dll/nvidia.so library
-- This loads the CloudXR plugin and makes its functions available
function CloudXRManager.init()
    print("Loading NVIDIA CloudXR Runtime plugin...")
    
    -- Use pcall to safely load the plugin (prevents crashes if plugin is missing)
    -- The 'nvidia' module is the CloudXR plugin built into LÖVR
    local success, plugin = pcall(require, 'nvidia')
    if not success then
        print("Failed to load NVIDIA CloudXR plugin:", plugin)
        return false
    end
    
    -- Store reference to the plugin for later use
    nv_cxr = plugin
    print("NVIDIA CloudXR plugin loaded successfully")
    return true
end

-- Initialize and start the CloudXR runtime service
-- This must be called BEFORE OpenXR initialization
function CloudXRManager.initRuntime(args)
    if not nv_cxr then
        print("NVIDIA CloudXR plugin not loaded")
        return false
    end

    -- Initialize the CloudXR plugin (loads the CloudXR library)
    if not nv_cxr.initRuntime() then
        print("Failed to initialize NVIDIA CloudXR plugin")
        nv_cxr.destroyRuntime()
        nv_cxr = nil
        return false
    end
    
    print("NVIDIA CloudXR plugin initialized")
    
    -- Display version information for debugging
    local major, minor, patch = nv_cxr.getRuntimeLibraryApiVersion()
    if major then
        print(string.format("CloudXR Library API Version: %d.%d.%d", major, minor, patch))
    else
        print("Could not get library API version")
    end

    major, minor, patch = nv_cxr.getRuntimeVersion()
    if major then
        print(string.format("CloudXR Runtime Version: %d.%d.%d", major, minor, patch))
    else
        print("Could not get runtime version")
    end

    -- Configure CloudXR runtime properties before starting the service
    -- These settings control how CloudXR behaves and which headset to target
    local deviceProfile, profileError = getDeviceProfile(args)
    if not deviceProfile then
        print(profileError)
        nv_cxr.destroyRuntime()
        return false
    end
    local shouldWaitForClient = shouldPollForDeviceProfile(deviceProfile)
    print("CloudXR device profile:", deviceProfile)

    if not nv_cxr.setRuntimeStringProperty("device-profile", deviceProfile) then
        print("Failed to set " .. deviceProfile .. " device profile")
        nv_cxr.destroyRuntime()
        return false
    end

    -- Enable audio streaming to the headset
    if not nv_cxr.setRuntimeBooleanProperty("audio-streaming", true) then
        print("Failed to set enable_audio property")
    end

    -- Native TLS: when both env vars are set, the runtime terminates wss://
    -- itself (no separate proxy). Property values are PEM file contents.
    local cert_path = os.getenv("CLOUDXR_CERT_PATH")
    local key_path = os.getenv("CLOUDXR_KEY_PATH")
    if cert_path and key_path then
        local function readPem(path)
            local f, err = io.open(path, "rb")
            if not f then
                print("Failed to open PEM file:", path, err)
                return nil
            end
            local content = f:read("*a")
            f:close()
            return content
        end

        local cert_pem = readPem(cert_path)
        local key_pem = readPem(key_path)
        if cert_pem and key_pem then
            -- Both properties must apply, or the runtime is left half-configured.
            local ok_cert = nv_cxr.setRuntimeStringProperty("certificate-pem", cert_pem)
            local ok_key = nv_cxr.setRuntimeStringProperty("key-pem", key_pem)
            if ok_cert and ok_key then
                print("CloudXR native TLS enabled (cert: " .. cert_path .. ")")
            else
                print("TLS not enabled: failed to set " ..
                      (not ok_cert and "certificate-pem" or "key-pem") .. " property")
            end
        else
            print("TLS not enabled: could not read " ..
                  (not cert_pem and "certificate" or "key") .. " PEM file")
        end
    elseif cert_path or key_path then
        print("Warning: CLOUDXR_CERT_PATH and CLOUDXR_KEY_PATH must both be set; TLS not enabled")
    end

    -- Start the CloudXR service - this begins the streaming process
    if not nv_cxr.startRuntime() then
        print("Failed to start CloudXR service (this is expected if CloudXR runtime is not available)")
        nv_cxr.destroyRuntime()
        return false
    end
    
    print("CloudXR service started successfully")

    waitingForClientConnection = shouldWaitForClient
    clientConnectionReady = not waitingForClientConnection

    if waitingForClientConnection then
        print("Waiting for CloudXR " .. deviceProfile .. " client connection...")
    end

    return true
end

function CloudXRManager.pollClientConnection()
    if not nv_cxr then
        print("NVIDIA CloudXR plugin not loaded")
        return nil
    end

    local wasReady = clientConnectionReady
    local result, eventType = nv_cxr.pollEvent()
    if result == nil then
        print("Failed to poll CloudXR service event")
        return nil
    end

    if result ~= nv_cxr.RESULT.SUCCESS then
        print("Failed to poll CloudXR service event:", result)
        return nil
    end

    if eventType == nv_cxr.EVENT.CLOUDXR_CLIENT_CONNECTED then
        clientConnectionReady = true
    elseif eventType == nv_cxr.EVENT.CLOUDXR_CLIENT_DISCONNECTED then
        clientConnectionReady = false
    end

    waitingForClientConnection = not clientConnectionReady

    if clientConnectionReady and not wasReady then
        print("CloudXR client is connected")
    elseif not clientConnectionReady and wasReady then
        print("CloudXR client disconnected; waiting for reconnect...")
    end

    return clientConnectionReady
end

function CloudXRManager.isWaitingForClientConnection()
    return waitingForClientConnection
end

-- Initialize opaque data channels for custom communication with the headset
-- This must be called AFTER OpenXR initialization
function CloudXRManager.initOpaqueDataChannel()
    if not nv_cxr then
        print("NVIDIA CloudXR plugin not loaded")
        return false
    end

    -- Load the OpenXR extension functions for opaque data channels
    if not nv_cxr.initOpaqueDataChannel() then
        print("Failed to load extension functions. Opaque data will not be available.")
        return false
    end

    print("OpenXR extension procedures loaded successfully")

    -- Create a unique identifier for our opaque data channel and store it for reconnects
    -- This UUID identifies this specific communication channel
    -- In a real application, you might want to generate a proper UUID
    -- This example uses "<LOVR Channel>" converted to bytes + padding
    CloudXRManager.opaque_uuid = {60, 76, 79, 86, 82, 32, 67, 104, 97, 110, 110, 101, 108, 62, 0, 0}

    -- Create the opaque data channel with our UUID
    if not nv_cxr.createOpaqueDataChannel(CloudXRManager.opaque_uuid) then
        print("Failed to create opaque data channel")
        return false
    end
    
    print("Opaque data channel created successfully")
    return true
end

-- Update function called every frame to process opaque data
-- This handles incoming data from the headset and sends outgoing data
function CloudXRManager.update()
    if not nv_cxr then
        print("NVIDIA CloudXR plugin not loaded")
        return false
    end

    -- Check if the opaque data channel is connected to a headset
    if nv_cxr.getOpaqueDataChannelState() == nv_cxr.OPAQUE_DATA_CHANNEL_STATUS.CONNECTED then
        -- Try to receive data from the headset
        local data = nv_cxr.receiveOpaqueDataChannel()
        if data then
            -- Log received data to console for debugging
            print("Received data:", data)
            lastReceivedData = data

            -- Echo the received data back to demonstrate bi-directional communication
            -- In a real application, you would process the data and send appropriate responses
            local success = nv_cxr.sendOpaqueDataChannel("Echo: " .. data)
            if not success then
                print("Failed to echo received data:", data)
            end
        end
    elseif nv_cxr.getOpaqueDataChannelState() == nv_cxr.OPAQUE_DATA_CHANNEL_STATUS.DISCONNECTED then
        -- Preserve the UUID before destroying the channel
        local uuid = CloudXRManager.opaque_uuid

        -- Fully destroy the channel to release runtime resources and re-create
        -- the channel with the same UUID
        nv_cxr.destroyOpaqueDataChannel()

        if uuid then
            nv_cxr.createOpaqueDataChannel(uuid)
        end
    end
end

-- Get the most recently received data from the headset
-- This is used by the renderer to display received data
function CloudXRManager.getLastReceivedData()
    return lastReceivedData
end

-- Clean up all CloudXR resources
-- This should be called when the application is shutting down
function CloudXRManager.destroy()
    if nv_cxr then
        print("  Destroying NVIDIA CloudXR plugin...")
        
        -- Clean up opaque data channel resources
        nv_cxr.destroyOpaqueDataChannel()
        
        -- Clean up CloudXR runtime service
        nv_cxr.destroyRuntime()
        
        -- Clear the plugin reference
        nv_cxr = nil
    end
    waitingForClientConnection = false
    clientConnectionReady = false
end

return CloudXRManager
