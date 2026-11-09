-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
-- SPDX-License-Identifier: Apache-2.0
-- Apply the documented management API properties before starting CloudXR.
return function(runtime)
    local ip = os.getenv("CLOUDXR_STUN_IP")
    local port = tonumber(os.getenv("CLOUDXR_STUN_PORT"))
    if not ip or not port then
        print("Cloud networking: missing STUN configuration")
        return false
    end
    local okIce = runtime.setRuntimeBooleanProperty("enable-ice", true)
    local okIp = runtime.setRuntimeStringProperty("stun-server-ip", ip)
    local okPort = runtime.setRuntimeInt64Property("stun-server-port", port)
    if not (okIce and okIp and okPort) then
        print("Cloud networking: runtime rejected ICE/STUN configuration")
        return false
    end
    local ice = runtime.getRuntimeBooleanProperty("enable-ice")
    local actualIp = runtime.getRuntimeStringProperty("stun-server-ip")
    -- The sample C binding includes the terminating NUL.
    if actualIp then actualIp = actualIp:gsub("%z$", "") end
    local actualPort = runtime.getRuntimeInt64Property("stun-server-port")
    if ice ~= true or actualIp ~= ip or actualPort ~= port then
        print("Cloud networking: ICE/STUN property verification failed")
        return false
    end
    print(string.format("Cloud networking verified: enable-ice=true stun-server-ip=%s stun-server-port=%d", ip, port))
    return true
end
