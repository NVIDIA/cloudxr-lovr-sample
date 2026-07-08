-- SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
-- SPDX-License-Identifier: MIT

-- Models are provided by immersive-web under the MIT license
-- https://github.com/immersive-web/webxr-input-profiles/blob/main/packages/assets/LICENSE.md
-- https://github.com/immersive-web/webxr-input-profiles/tree/main/packages/assets/profiles/meta-quest-touch-plus

print("NVIDIA CloudXR Plugin Example")

-- Headless mode (--headless): a headless server/cloud GPU has no presentable
-- Vulkan surface, so LÖVR's default run loop would fail at getWindowPass()/
-- present(). When --headless is set, install a run loop that renders and submits
-- only the headset (OpenXR) pass — frames still flow to the CloudXR runtime —
-- and skips all desktop-window work.
local function isHeadless()
    if arg then
        for _, argument in ipairs(arg) do
            if argument == "--headless" then
                return true
            end
        end
    end
    return false
end

if isHeadless() then
    function lovr.run()
        if lovr.timer then lovr.timer.step() end
        if lovr.load then lovr.load(arg) end
        return function()
            if lovr.headset then lovr.headset.pollEvents() end
            if lovr.system then lovr.system.pollEvents() end
            if lovr.event then
                for name, a, b, c, d in lovr.event.poll() do
                    if name == 'restart' then
                        return 'restart', lovr.restart and lovr.restart()
                    elseif name == 'quit' and (not lovr.quit or not lovr.quit(a)) then
                        return a or 0
                    elseif name ~= 'quit' and lovr.handlers[name] then
                        lovr.handlers[name](a, b, c, d)
                    end
                end
            end
            local dt = 0
            if lovr.timer then dt = lovr.timer.step() end
            if lovr.headset then lovr.headset.update(dt) end
            if lovr.update then lovr.update(dt) end
            if lovr.audio then lovr.audio.update(dt) end
            if lovr.graphics then
                local headset = lovr.headset and lovr.headset.getPass()
                if headset and (not lovr.draw or lovr.draw(headset)) then headset = nil end
                lovr.graphics.submit(headset)
            end
            if lovr.headset then lovr.headset.submit() end
            if lovr.math then lovr.math.drain() end
        end
    end
end

-- Import our custom modules
-- These handle different aspects of the CloudXR integration
local CloudXRManager = require('cloudxr_manager')  -- Manages CloudXR runtime and opaque data channels
local HeadsetManager = require('headset_manager')  -- Manages OpenXR headset initialization
local Renderer = require('renderer')               -- Handles rendering of VR content and data
local AudioManager = require('audio_manager')      -- Manages audio playback triggered by hand gestures
-- Mutually-exclusive lifecycle states. Transitions live in lovr.load,
-- initializeHeadsetStack, and lovr.update.
local STATE = {
    IDLE = "IDLE",                                 -- before async/sync init kicks in
    WAITING_FOR_CLIENT = "WAITING_FOR_CLIENT",     -- auto-* profile, waiting for CloudXR client
    WAITING_FOR_HEADSET = "WAITING_FOR_HEADSET",   -- client connected, OpenXR not yet ready
    INITIALIZED = "INITIALIZED",                   -- headset + opaque + audio ready
    FAILED = "FAILED",                             -- terminal error
}

local AppState = {
    state = STATE.IDLE,
    retryHeadsetOnFormFactor = false,              -- mode flag (set once for auto-* profiles)
    headsetRetryTimer = 0.0,
    headsetRetryLogged = false,
}

local HEADSET_RETRY_INTERVAL = 0.5

local HapticsHarness = {
    demoEnabled = false,
    demoTimer = 0,
    demoStep = 0,
    previousButtons = {
        left = { trigger = false, grip = false },
        right = { trigger = false, grip = false }
    },
    previousKeys = {
        ["1"] = false,
        ["2"] = false,
        ["3"] = false,
        ["4"] = false,
        ["5"] = false
    },
    pendingReplacement = nil,
    eventCount = 0,
    lastEvent = {
        action = "none",
        hand = "none",
        amplitude = 0.0,
        duration = 0.0,
        frequency = 0.0,
        success = false,
        count = 0
    }
}

local function recordHapticsEvent(hand, action, amplitude, duration, frequency, success)
    HapticsHarness.eventCount = HapticsHarness.eventCount + 1
    HapticsHarness.lastEvent = {
        action = action,
        hand = hand,
        amplitude = amplitude or 0.0,
        duration = duration or 0.0,
        frequency = frequency or 0.0,
        success = success == true,
        count = HapticsHarness.eventCount
    }
    print(string.format(
        "Haptics event #%d: action=%s hand=%s amp=%.2f dur=%.2f freq=%.2f success=%s",
        HapticsHarness.eventCount,
        action,
        hand,
        amplitude or 0.0,
        duration or 0.0,
        frequency or 0.0,
        tostring(success == true)
    ))
end

local function canVibrate()
    return lovr.headset and type(lovr.headset.vibrate) == "function"
end

local function triggerBuzz(hand, amplitude, duration, frequency, actionLabel)
    if not canVibrate() then
        recordHapticsEvent(hand, actionLabel or "buzz", amplitude, duration, frequency, false)
        return false
    end

    local success = lovr.headset.vibrate(hand, amplitude, duration, frequency)
    recordHapticsEvent(hand, actionLabel or "buzz", amplitude, duration, frequency, success)
    return success
end

local function stopBuzz(hand, actionLabel)
    if lovr.headset and type(lovr.headset.stopVibration) == "function" then
        lovr.headset.stopVibration(hand)
        recordHapticsEvent(hand, actionLabel or "stop", 0.0, 0.0, 0.0, true)
        return true
    end

    recordHapticsEvent(hand, actionLabel or "stop", 0.0, 0.0, 0.0, false)
    return false
end

local function triggerBothBuzz(amplitude, duration, frequency, actionLabel)
    local leftSuccess = triggerBuzz('left', amplitude, duration, frequency, actionLabel or "both-left")
    local rightSuccess = triggerBuzz('right', amplitude, duration, frequency, actionLabel or "both-right")
    recordHapticsEvent("both", actionLabel or "both", amplitude, duration, frequency, leftSuccess and rightSuccess)
end

local function scheduleReplacement(hand, delaySeconds, amplitude, duration, frequency)
    HapticsHarness.pendingReplacement = {
        hand = hand,
        delay = delaySeconds,
        amplitude = amplitude,
        duration = duration,
        frequency = frequency
    }
end

local function triggerReplacementTest(hand)
    triggerBuzz(hand, 1.0, 0.50, 0.0, "replacement-start")
    scheduleReplacement(hand, 0.10, 0.30, 0.15, 0.0)
end

local function updateManualKeyboardHaptics()
    if not lovr.system then
        return
    end

    local keys = {
        ["1"] = function() triggerBuzz('left', 1.0, 0.15, 0.0, "keyboard-left") end,
        ["2"] = function() triggerBuzz('right', 1.0, 0.15, 0.0, "keyboard-right") end,
        ["3"] = function() triggerBothBuzz(1.0, 0.15, 0.0, "keyboard-both") end,
        ["4"] = function() triggerReplacementTest('left') end,
        ["5"] = function()
            stopBuzz('left', "keyboard-stop-left")
            stopBuzz('right', "keyboard-stop-right")
            recordHapticsEvent("both", "keyboard-stop-both", 0.0, 0.0, 0.0, true)
        end
    }

    for key, callback in pairs(keys) do
        local isDown = lovr.system.isKeyDown(key)
        if isDown and not HapticsHarness.previousKeys[key] then
            callback()
        end
        HapticsHarness.previousKeys[key] = isDown
    end
end

local function updateControllerHaptics()
    local bindings = {
        left = { triggerAction = "left-manual-buzz", stopAction = "left-manual-stop" },
        right = { triggerAction = "right-manual-buzz", stopAction = "right-manual-stop" }
    }

    for hand, labels in pairs(bindings) do
        local triggerDown = lovr.headset.isDown(hand, 'trigger')
        local gripDown = lovr.headset.isDown(hand, 'grip')

        if triggerDown and not HapticsHarness.previousButtons[hand].trigger then
            triggerBuzz(hand, 1.0, 0.15, 0.0, labels.triggerAction)
        end

        if gripDown and not HapticsHarness.previousButtons[hand].grip then
            stopBuzz(hand, labels.stopAction)
        end

        HapticsHarness.previousButtons[hand].trigger = triggerDown
        HapticsHarness.previousButtons[hand].grip = gripDown
    end
end

local function updatePendingReplacement(dt)
    if not HapticsHarness.pendingReplacement then
        return
    end

    HapticsHarness.pendingReplacement.delay = HapticsHarness.pendingReplacement.delay - dt
    if HapticsHarness.pendingReplacement.delay <= 0 then
        local pending = HapticsHarness.pendingReplacement
        HapticsHarness.pendingReplacement = nil
        triggerBuzz(
            pending.hand,
            pending.amplitude,
            pending.duration,
            pending.frequency,
            "replacement-finish"
        )
    end
end

local function updateDemoMode(dt)
    if not HapticsHarness.demoEnabled then
        return
    end

    HapticsHarness.demoTimer = HapticsHarness.demoTimer + dt
    if HapticsHarness.demoTimer < 1.50 then
        return
    end

    HapticsHarness.demoTimer = 0
    HapticsHarness.demoStep = (HapticsHarness.demoStep % 5) + 1

    if HapticsHarness.demoStep == 1 then
        triggerBuzz('left', 1.0, 0.15, 0.0, "demo-left")
    elseif HapticsHarness.demoStep == 2 then
        triggerBuzz('right', 1.0, 0.15, 0.0, "demo-right")
    elseif HapticsHarness.demoStep == 3 then
        triggerBothBuzz(1.0, 0.15, 0.0, "demo-both")
    elseif HapticsHarness.demoStep == 4 then
        triggerReplacementTest('left')
    else
        stopBuzz('left', "demo-stop-left")
        stopBuzz('right', "demo-stop-right")
        recordHapticsEvent("both", "demo-stop-both", 0.0, 0.0, 0.0, true)
    end
end

-- Parse command line arguments to check for special flags
-- This allows users to modify behavior without changing code
local function printUsage()
    print("Usage: lovr plugins/nvidia/examples/cloudxr [options]")
    print("  --device-profile=<profile>  CloudXR device profile (default: apple-vision-pro)")
    print("  --use_system_runtime        Do not start the bundled CloudXR runtime")
end

local function parseArgs(rawArgs)
    local args = {}
    rawArgs = rawArgs or arg or {}

    for _, argStr in ipairs(rawArgs) do
        if argStr == "-h" then
            args.h = true
            print("Flag enabled: h")
        elseif type(argStr) == "string" and argStr:sub(1, 2) == "--" then
            local option = argStr:sub(3)
            local equals = option:find("=", 1, true)
            local optionName = equals and option:sub(1, equals - 1) or option
            if optionName == "webrtc" then
                args._error = "--webrtc has been removed; use --device-profile=auto-webrtc"
            elseif equals then
                local optionValue = option:sub(equals + 1)
                args[optionName] = optionValue
                print("Option set:", optionName .. "=" .. optionValue)
            else
                args[option] = true
                print("Flag enabled:", option)
            end
        end
    end

    return args
end

local function initializeHeadsetStack()
    if AppState.state == STATE.INITIALIZED or AppState.state == STATE.FAILED then
        return AppState.state == STATE.INITIALIZED
    end

    -- Initialize OpenXR headset and graphics
    -- This creates the OpenXR instance and starts VR rendering
    local initialized, errMsg = HeadsetManager.init()
    if not initialized then
        if AppState.retryHeadsetOnFormFactor and HeadsetManager.isFormFactorUnavailable(errMsg) then
            if not AppState.headsetRetryLogged then
                print("OpenXR form factor unavailable; waiting for CloudXR headset system...")
                AppState.headsetRetryLogged = true
            end
            AppState.state = STATE.WAITING_FOR_HEADSET
            AppState.headsetRetryTimer = HEADSET_RETRY_INTERVAL
            return false
        end

        print("Failed to initialize headset")
        if errMsg then
            print("Headset initialization error:", errMsg)
        end
        AppState.state = STATE.FAILED
        return false
    end

    AppState.headsetRetryTimer = 0.0
    -- Initialize opaque data channels AFTER OpenXR is ready
    -- This enables custom communication between app and headset
    if not CloudXRManager.initOpaqueDataChannel() then
        print("Failed to initialize Opaque Data Channel")
        AppState.state = STATE.FAILED
        return false
    end

    -- Initialize audio manager for hand gesture-triggered audio playback
    if not AudioManager.init() then
        print("Failed to initialize Audio Manager")
        -- Continue anyway, audio is not critical
    end

    AppState.state = STATE.INITIALIZED
    print("Application initialized successfully")
    return true
end


-- LÖVR load function - called once when the application starts
-- This is where we initialize all our modules in the correct order
function lovr.load(args)
    print("Loading CloudXR manager...")    
    
    -- Parse command line arguments first
    local parsedArgs = parseArgs(args)
    if parsedArgs.help or parsedArgs.h then
        printUsage()
        if lovr.event then
            lovr.event.quit()
        end
        return
    end

    if parsedArgs._error then
        print(parsedArgs._error)
        printUsage()
        AppState.state = STATE.FAILED
        if lovr.event then
            lovr.event.quit()
        end
        return
    end
    HapticsHarness.demoEnabled = parsedArgs.haptics_demo == true
    
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
            AppState.state = STATE.FAILED
            return
        end
    else
        print("Skipping CloudXR Runtime initialization (--use_system_runtime flag detected)")
    end
    
    AppState.useSystemRuntime = parsedArgs.use_system_runtime == true

    if CloudXRManager.isWaitingForClientConnection() and not parsedArgs.use_system_runtime then
        AppState.state = STATE.WAITING_FOR_CLIENT
        AppState.retryHeadsetOnFormFactor = true
        return
    end

    -- A system auto-* runtime only learns its form factor once the CloudXR client
    -- connects, so don't fail on the first headset init -- keep retrying until
    -- OpenXR exposes the form factor (i.e. the client has connected). nv_cxr event
    -- polling isn't available here (initRuntime was skipped), so lovr.update drives
    -- the retry off form-factor availability instead of client-connect events.
    local isAutoProfile = type(parsedArgs["device-profile"]) == "string"
        and parsedArgs["device-profile"]:sub(1, 5) == "auto-"
    if parsedArgs.use_system_runtime and isAutoProfile then
        AppState.retryHeadsetOnFormFactor = true
    end

    initializeHeadsetStack()
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
    if AppState.state ~= STATE.INITIALIZED then
        return
    end

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
    if HapticsHarness.demoEnabled then
        Renderer.drawHapticsStatus(pass, HapticsHarness.lastEvent, HapticsHarness.demoEnabled)
    end
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

    if AppState.state ~= STATE.INITIALIZED then
        if AppState.retryHeadsetOnFormFactor and AppState.state ~= STATE.FAILED then
            -- System runtime: nv_cxr event polling isn't initialized (initRuntime
            -- was skipped), so drive the retry off OpenXR form-factor availability
            -- instead of client-connect events. Keep retrying headset init until
            -- the runtime exposes the form factor (the CloudXR client connected).
            if AppState.useSystemRuntime then
                AppState.headsetRetryTimer = AppState.headsetRetryTimer - dt
                if AppState.headsetRetryTimer <= 0 then
                    AppState.headsetRetryTimer = HEADSET_RETRY_INTERVAL
                    initializeHeadsetStack()
                end
                return
            end

            local connected = CloudXRManager.pollClientConnection()
            if connected == nil then
                AppState.state = STATE.FAILED
                return
            end

            if not connected then
                AppState.state = STATE.WAITING_FOR_CLIENT
                AppState.headsetRetryTimer = 0.0
                return
            end

            -- Client is connected; advance based on which wait we were in.
            -- initializeHeadsetStack will transition to INITIALIZED,
            -- WAITING_FOR_HEADSET, or FAILED on its own.
            if AppState.state == STATE.WAITING_FOR_CLIENT then
                initializeHeadsetStack()
            elseif AppState.state == STATE.WAITING_FOR_HEADSET then
                AppState.headsetRetryTimer = AppState.headsetRetryTimer - dt
                if AppState.headsetRetryTimer <= 0 then
                    initializeHeadsetStack()
                end
            end
        end
        return
    end

    -- Only update if the headset is active and tracking
    if not HeadsetManager.isActive() then
        return
    end

    updatePendingReplacement(dt)
    updateDemoMode(dt)
    updateManualKeyboardHaptics()
    updateControllerHaptics()
    
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
