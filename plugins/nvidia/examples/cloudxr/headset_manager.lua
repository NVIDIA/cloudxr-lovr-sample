-- SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
-- SPDX-License-Identifier: MIT

-- Models left.glb and right.glb are provided by immersive-web under the MIT license
-- https://github.com/immersive-web/webxr-input-profiles/blob/main/packages/assets/LICENSE.md
-- https://github.com/immersive-web/webxr-input-profiles/tree/main/packages/assets/profiles/meta-quest-touch-plus

local HeadsetManager = {}

local models = {}
local FORM_FACTOR_UNAVAILABLE = "XR_ERROR_FORM_FACTOR_UNAVAILABLE"

function HeadsetManager.isFormFactorUnavailable(errMsg)
    return type(errMsg) == "string" and errMsg:find(FORM_FACTOR_UNAVAILABLE, 1, true) ~= nil
end


function HeadsetManager.init()
    -- Now that CloudXR OpenXR Runtime is started, we can load the headset module, which starts the OpenXR instance.
    local headsetSuccess, headsetOrErr = pcall(require, "lovr.headset")
    if not headsetSuccess then
        print("Failed to load headset module:", headsetOrErr)
        return false, headsetOrErr
    end

    lovr.headset = headsetOrErr

    -- Connect to the OpenXR runtime
    local connected, errMsg = lovr.headset.connect()
    if not connected then
        if not HeadsetManager.isFormFactorUnavailable(errMsg) then
            print("Failed to connect headset:", errMsg)
        end
        return false, errMsg
    end

    local graphicsSuccess, graphicsOrErr = pcall(require, "lovr.graphics")
    if not graphicsSuccess then
        print("Failed to load graphics module:", graphicsOrErr)
        HeadsetManager.cleanup()
        return false, graphicsOrErr
    end
    lovr.graphics = graphicsOrErr

    local graphicsInitialized, graphicsErr = pcall(lovr.graphics.initialize)
    if not graphicsInitialized then
        print("Failed to initialize graphics:", graphicsErr)
        HeadsetManager.cleanup()
        return false, graphicsErr
    end

    local registry = debug.getregistry()
    local conf = registry._lovrconf
    -- In headless mode conf.lua leaves t.window nil, so there is no window to open.
    if conf.window then
        local windowOpened, windowErr = pcall(lovr.system.openWindow, conf.window)
        if not windowOpened then
            print("Failed to open window:", windowErr)
            HeadsetManager.cleanup()
            return false, windowErr
        end
    end

    local started, errMsg = lovr.headset.start()
    if not started then
        print("Failed to start headset: ", errMsg)
        HeadsetManager.cleanup()
        return false, errMsg
    end

    -- Load controller models
    local modelsLoaded, modelErr = pcall(function()
        models = {
            left = lovr.graphics.newModel("meta-quest-touch-plus/left.glb"),
            right = lovr.graphics.newModel("meta-quest-touch-plus/right.glb")
        }
    end)
    if not modelsLoaded then
        print("Failed to load controller models:", modelErr)
        HeadsetManager.cleanup()
        return false, modelErr
    end

    return true
end

function HeadsetManager.getModels()
    return models
end

function HeadsetManager.isActive()
    return lovr.headset and lovr.headset.isActive()
end

function HeadsetManager.cleanup()
    models = {}

    -- Stop headset session first (OpenXR cleanup)
    if lovr.headset and lovr.headset.stop then
        pcall(lovr.headset.stop)
    end

    -- Clear module references (for determinism)
    if lovr.headset then
        lovr.headset = nil
    end

    if lovr.graphics then
        lovr.graphics = nil
    end

    if lovr.system then
        lovr.system = nil
    end
end

return HeadsetManager
