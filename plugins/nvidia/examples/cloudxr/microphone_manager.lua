-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
-- SPDX-License-Identifier: MIT

-- Optional server-side capture of the CloudXR virtual microphone. A client mic
-- icon or a capture callback alone is not evidence of upstream speech delivery.
local MicrophoneManager = {}
local enabled = false
local sink = nil
local retryTime = 0
local elapsed = 0
local deviceName = "none"
local status = "disabled"
local detail = ""
local rms = 0
local peak = 0
local totalFrames = 0
local silenceThreshold = 0.001 -- -60 dBFS; a display label, not a QA pass threshold.

local function fail(message)
    if sink and lovr.audio then pcall(lovr.audio.stop, 'capture') end
    sink = nil
    status = "Setup error"
    detail = tostring(message)
    rms, peak = 0, 0
    print("Microphone upstream: " .. detail)
end

function MicrophoneManager.init(args, setupError)
    enabled = args and args["mic-demo"] == true
    if not enabled then return end
    if not lovr.system or lovr.system.getOS() ~= "Windows" then
        fail("CloudXR recording-device capture requires a Windows server.")
    elseif setupError then
        fail(setupError)
    elseif not lovr.audio then
        fail("LÖVR audio module is unavailable.")
    else
        status = "Waiting for recording device"
        detail = "Install the CloudXR virtual audio driver before starting the runtime."
    end
end

local function openCapture()
    local matches = {}
    for _, device in ipairs(lovr.audio.getDevices('capture')) do
        -- The endpoint friendly name can include "Microphone" and driver suffixes.
        -- Never substitute a physical/default PC mic when the CloudXR input is absent.
        if device.name:lower():find('nvidia', 1, true)
            and device.name:lower():find('cloudxr', 1, true) then
            matches[#matches + 1] = device
        end
    end
    if #matches == 0 then return end
    if #matches > 1 then
        fail("Multiple NVIDIA CloudXR recording devices found; disable unused endpoints and restart.")
        return
    end
    deviceName = matches[1].name
    sink = lovr.data.newAudioStream(48000, 'f32', 2, 48000)
    local selected, selectError = lovr.audio.setDevice('capture', matches[1].id, sink)
    if not selected then error(selectError or "Could not open the CloudXR recording device") end
    local started, startError = lovr.audio.start('capture')
    if not started then error(startError or "Could not start microphone capture") end
    status = "No capture data"
    detail = "Speech response + client mute/unmute verify upstream delivery."
    print("Microphone upstream recording device: " .. deviceName)
end

local function drainCapture()
    local sum, maximum, frameCount = 0, 0, 0
    -- Read at most the queued snapshot; the audio callback may keep adding frames.
    -- Read capacity is in frames; read returns a fresh interleaved sample table.
    local remaining = sink:getReadCapacity()
    while remaining > 0 do
        local samples = sink:read(math.min(remaining, 2048))
        local frames = #samples / 2
        if frames == 0 then break end
        for i = 1, frames * 2 do
            local value = samples[i]
            sum = sum + value * value
            maximum = math.max(maximum, math.abs(value))
        end
        frameCount = frameCount + frames
        remaining = remaining - frames
    end
    totalFrames = totalFrames + frameCount
    -- Clear immediately on no data, rather than retaining a previous speech peak.
    rms = frameCount > 0 and math.sqrt(sum / (frameCount * 2)) or 0
    peak = maximum
    status = frameCount == 0 and "No capture data"
        or (rms < silenceThreshold and "Quiet input" or "Audio signal")
end

function MicrophoneManager.update(dt)
    if not enabled or status == "Setup error" then return end
    elapsed = elapsed + dt
    if not sink then
        retryTime = retryTime - dt
        if retryTime > 0 then return end
        retryTime = 0.5
        local ok, err = pcall(openCapture)
        if not ok then fail(err) end
        if not sink and status ~= "Setup error" and elapsed >= 10 then
            fail("No NVIDIA CloudXR recording device after 10 seconds. Check the driver/runtime and restart.")
        end
        return
    end
    local ok, err = pcall(drainCapture)
    if not ok then
        pcall(lovr.audio.stop, 'capture')
        fail("Capture failed: " .. tostring(err))
    end
end

function MicrophoneManager.draw(pass)
    if not enabled then return end
    local db = 20 * math.log(math.max(rms, 0.000001)) / math.log(10)
    local amplitude = math.min(1, math.max(0, (60 + db) / 60))
    local bars = math.floor(amplitude * 20)

    -- Lower right: opaque event text is centered at y=1.7, and haptics is left.
    -- Keep the endpoint inside a fixed-width label, with the meter below it.
    -- Long custom names are shortened; the selected full name is logged on open.
    local deviceLabel = #deviceName > 32 and deviceName:sub(1, 29) .. "..." or deviceName
    local header = lovr.math.mat4():translate(1.05, 1.05, -1.8):scale(0.06)
    pass:setColor(1, 1, 1, 1)
    pass:text("Microphone upstream\n" .. deviceLabel, header, 16, 'center', 'top')

    local meter = lovr.math.mat4():translate(1.05, 0.78, -1.8):scale(0.06)
    if status == "Setup error" then
        pass:setColor(1, 0.3, 0.3, 1)
        pass:text("Setup error: " .. detail, meter, 16, 'center', 'top')
    elseif status == "Waiting for recording device" or status == "No capture data" then
        pass:setColor(0.6, 0.6, 0.6, 1)
        pass:text(status, meter, 16)
    else
        -- Logarithmic scale makes ordinary speech visible: green at -60 dBFS,
        -- yellow at -30 dBFS, red at 0 dBFS. Color indicates amplitude only.
        pass:setColor(math.min(1, amplitude * 2), math.min(1, (1 - amplitude) * 2), 0, 1)
        pass:text("[" .. string.rep('|', bars) .. string.rep('.', 20 - bars) .. "]", meter)
    end
    pass:setColor(1, 1, 1, 1)
end

function MicrophoneManager.cleanup()
    if sink and lovr.audio then pcall(lovr.audio.stop, 'capture') end
    sink = nil
end

return MicrophoneManager
