-- SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
-- SPDX-License-Identifier: MIT

-- Audio Manager Module
-- This example module handles audio playback triggered by hand gestures
-- Specifically, plays a 440 Hz tone when pinching right index finger and thumb

local AudioManager = {}

-- Constants for pinch detection
local PINCH_THRESHOLD = 0.03  -- Distance threshold in meters for pinch detection
local PINCH_RELEASE_THRESHOLD = 0.05  -- Slightly larger threshold for release (hysteresis)

-- Hand joint indices
local HAND_JOINT = {
    THUMB_TIP = 5,
    INDEX_TIP = 10
}

-- State variables
local audioSource = nil
local wasPinching = false

-- Helper function to calculate distance between two 3D points
local function distance3D(x1, y1, z1, x2, y2, z2)
    local dx = x2 - x1
    local dy = y2 - y1
    local dz = z2 - z1
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Initialize the audio system and load the tone sound
function AudioManager.init()
    print("Initializing Audio Manager...")
    
    if not lovr.audio then
        print("Error: lovr.audio module not available")
        return false
    end
    
    -- Load the tone sound and create an audio source
    local success, result = pcall(function()
        return lovr.audio.newSource('tone.wav', {
            spatial = false,  -- Non-spatial audio (plays at listener position)
            pitchable = false -- Don't need pitch variation
        })
    end)
    
    if not success then
        print("Error loading tone.wav:", result)
        return false
    end
    
    audioSource = result
    print("Audio Manager initialized successfully")
    return true
end

-- Check if right hand is pinching (index finger tip close to thumb tip)
local function isRightHandPinching()
    if not lovr.headset then
        return false
    end
    
    -- Get right hand skeleton data
    local joints = lovr.headset.getSkeleton('right')
    if not joints then
        return false
    end
    
    -- Get thumb tip position
    local thumbTip = joints[HAND_JOINT.THUMB_TIP + 1]  -- Lua is 1-indexed
    if not thumbTip then
        return false
    end
    
    -- Get index finger tip position
    local indexTip = joints[HAND_JOINT.INDEX_TIP + 1]  -- Lua is 1-indexed
    if not indexTip then
        return false
    end
    
    -- Calculate distance between thumb tip and index finger tip
    -- Joint format: {x, y, z, radius, qx, qy, qz, qw}
    local dist = distance3D(
        thumbTip[1], thumbTip[2], thumbTip[3],
        indexTip[1], indexTip[2], indexTip[3]
    )
    
    -- Use hysteresis to avoid jitter: 
    -- - Detect pinch at smaller threshold
    -- - Detect release at larger threshold
    if wasPinching then
        return dist < PINCH_RELEASE_THRESHOLD
    else
        return dist < PINCH_THRESHOLD
    end
end

-- Update function called every frame to check for pinch gesture
function AudioManager.update()
    if not audioSource then
        return
    end
    
    local isPinching = isRightHandPinching()
    
    -- Trigger audio on pinch start (edge detection)
    if isPinching and not wasPinching then
        print("Right hand pinch detected! Playing tone...")
        audioSource:stop()
        audioSource:play()
    end
    
    wasPinching = isPinching
end

-- Clean up audio resources
function AudioManager.cleanup()
    if audioSource then
        audioSource:stop()
        audioSource = nil
    end
    print("Audio Manager cleaned up")
end

return AudioManager

