-- SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
-- SPDX-License-Identifier: MIT

-- Models left.glb and right.glb are provided by immersive-web under the MIT license
-- https://github.com/immersive-web/webxr-input-profiles/blob/main/packages/assets/LICENSE.md
-- https://github.com/immersive-web/webxr-input-profiles/tree/main/packages/assets/profiles/meta-quest-touch-plus

local HeadsetManager = {}

local models = {}

function HeadsetManager.init()
    -- Now that CloudXR OpenXR Runtime is started, we can load the headset module, which starts the OpenXR instance.
    local headsetSuccess, headset = pcall(require, "lovr.headset")
    if not headsetSuccess then
        print("Failed to load headset module:", headset)
        return false
    end

    lovr.headset = headset

    -- Connect to the OpenXR runtime
    local connected, errMsg = lovr.headset.connect()
    if not connected then
        print("Failed to connect headset:", errMsg)
        return false
    end
    
    local graphicsSuccess, graphics = pcall(require, "lovr.graphics")
    if not graphicsSuccess then
        print("Failed to load graphics module:", graphics)
        return false
    end
    lovr.graphics = graphics
    lovr.graphics.initialize()

    local registry = debug.getregistry()
    local conf = registry._lovrconf        
    lovr.system.openWindow(conf.window)

    local started, errMsg = lovr.headset.start()
    if not started then
        print("Failed to start headset: ", errMsg)
        return false
    end

    -- Load controller models
    models = {
        left = lovr.graphics.newModel('meta-quest-touch-plus/left.glb'),
        right = lovr.graphics.newModel('meta-quest-touch-plus/right.glb')
    }
    
    return true
end

function HeadsetManager.getModels()
    return models
end

function HeadsetManager.isActive()
    return lovr.headset and lovr.headset.isActive()
end

function HeadsetManager.cleanup()
    -- Step 1: Stop headset session first (OpenXR cleanup)
    if lovr.headset then
        lovr.headset = nil
    end
    
    -- Step 2: Clear module references (for determinism)
    if lovr.graphics then
        lovr.graphics = nil
    end

    if lovr.system then
        lovr.system = nil
    end
end

return HeadsetManager
