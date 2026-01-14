-- SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
-- SPDX-License-Identifier: MIT

local Renderer = {}

-- Helper function to draw text at a specific position and orientation
local function drawText(pass, text, mat, offset, scale)
    scale = scale or 0.05
    -- Create a copy of the matrix to avoid modifying the original
    local textMat = mat4(mat)
    -- Apply the offset in the controller's local space
    textMat:translate(offset[1], offset[2], offset[3])
    textMat:scale(scale, scale, scale)
    -- Draw text using the transformed matrix
    pass:text(text, textMat)
end

-- Helper function to draw a button state
local function drawButtonState(pass, device, button, mat, offset, label)
    local isDown = lovr.headset.isDown(device, button)
    local color = isDown and {1, 0, 0, 1} or {0.5, 0.5, 0.5, 1}
    pass:setColor(unpack(color))
    drawText(pass, label .. ": " .. (isDown and "DOWN" or "up"), mat, offset)
end

-- Helper function to draw axis values
local function drawAxisValues(pass, device, axis, mat, offset, label)
    local values = {lovr.headset.getAxis(device, axis)}
    if #values > 0 then
        local text = label .. ": "
        for i, v in ipairs(values) do
            text = text .. string.format("%.2f", v) .. (i < #values and ", " or "")
        end
        pass:setColor(0, 1, 0, 1)  -- Green for axis values
        drawText(pass, text, mat, offset)
    end
end

function Renderer.drawOpaqueData(pass, lastReceivedData)
    -- Display the received opaque data as text in 3D space
    local displayText = lastReceivedData or "no data"
    pass:text('Received: ' .. displayText, 0, 1.7, -3, .5)
end

function Renderer.drawHandJoints(pass, lastReceivedData)
    -- Display the received opaque data as text in 3D space
    local displayText = lastReceivedData or "no data"
    pass:text('Received: ' .. displayText, 0, 1.7, -3, .5)
 
    -- Set color to blue for hand joint visualization
    pass:setColor(0, 0, 1, 1)
  
    -- Visualize hand joints for both hands
    for _, hand in ipairs({ 'left', 'right' }) do
        local joints = lovr.headset.getSkeleton(hand)
        if joints then
            for _, joint in ipairs(joints) do
                -- Create a transformation matrix for each joint
                -- This combines position, rotation, and scale into a single 4x4 matrix
                local mat = lovr.math.mat4()
                mat:translate(joint[1], joint[2], joint[3])  -- Set joint position
                mat:rotate(joint[5], joint[6], joint[7], joint[8])  -- Apply joint rotation
                mat:scale(joint.radius or .05)  -- Scale based on joint radius
                
                -- Render a cube at the joint position with proper orientation
                pass:cube(mat)
            end
        end
    end
end

function Renderer.drawControllers(pass, models)
    -- Draw controller models and input states
    for hand, model in pairs(models) do
        -- Skip controller rendering if hand tracking is active
        if not lovr.headset.getSkeleton(hand) then
            -- Get controller pose matrix
            local mat = mat4(lovr.headset.getPose(hand))
            
            -- Draw controller model
            pass:setColor(1, 1, 1, 1)
            pass:draw(model, mat)
            
            -- Draw input visualization relative to controller
            local yOffset = 0.2  -- Offset from controller position
            local spacing = 0.035
            local xOffset = (hand == 'left' and -0.1 or 0.1)  -- Offset left/right of controller
            
            -- Rotate -75 degrees around X axis to pitch text away from controller
            mat:rotate(-math.pi/2.5, 1, 0, 0)

            -- Draw controller label
            pass:setColor(1, 1, 1, 1)
            drawText(pass, hand:upper(), mat, {xOffset, yOffset, 0}, 0.1)
            
            -- Draw button states
            local buttons = {
                {button = "trigger", label = "Trigger"},
                {button = "thumbstick", label = "Thumbstick"},
                {button = "thumbrest", label = "Thumb Rest"},
                {button = "grip", label = "Grip"},
                {button = "menu", label = "Menu"},
                {button = "a", label = "A"},
                {button = "b", label = "B"},
                {button = "x", label = "X"},
                {button = "y", label = "Y"}
            }
            
            for j, btn in ipairs(buttons) do
                drawButtonState(pass, hand, btn.button, mat, 
                    {xOffset, yOffset - j * spacing, 0}, btn.label)
            end
            
            -- Draw axis values
            local axes = {
                {axis = "trigger", label = "Trigger"},
                {axis = "thumbstick", label = "Thumbstick"},
                {axis = "grip", label = "Grip"}
            }
            
            for j, ax in ipairs(axes) do
                drawAxisValues(pass, hand, ax.axis, mat,
                    {xOffset, yOffset - (j + #buttons) * spacing, 0}, ax.label)
            end
        end
    end

    -- Draw instructions (in world space, not relative to controller)
    pass:setColor(1, 1, 1, 1)
end

return Renderer
