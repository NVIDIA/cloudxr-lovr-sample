// SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: MIT

#include "nvidia_cloudxr_opaque_data.h"
#include "nvidia_cloudxr_runtime.h"
#include <headset/headset.h>
#include <util.h>

#define XR_NO_PROTOTYPES
#include <openxr/openxr.h>

// Workaround: xr_get_instance() and xr_get_system() are not declared in headset.h.
// Without explicit declarations, the compiler assumes they return int (implicit declaration),
// which truncates the upper 32 bits of the returned pointer on 64-bit systems.
// Redeclare them here with the correct return type to prevent this truncation.
uintptr_t xr_get_instance(void);
uintptr_t xr_get_system(void);

static CloudXROpaqueDataState cxrOpaqueDataState = {0};

bool cxrOpaqueDataChannelInit() {
    // Function name to function pointer mapping
    static const struct {
        const char* name;
        void** ptr;
    } function_map[] = {
        {"xrCreateOpaqueDataChannelNV", (void**)&cxrOpaqueDataState.xrCreateOpaqueDataChannel},
        {"xrDestroyOpaqueDataChannelNV", (void**)&cxrOpaqueDataState.xrDestroyOpaqueDataChannel},
        {"xrGetOpaqueDataChannelStateNV", (void**)&cxrOpaqueDataState.xrGetOpaqueDataChannelState},
        {"xrSendOpaqueDataChannelNV", (void**)&cxrOpaqueDataState.xrSendOpaqueDataChannel},
        {"xrReceiveOpaqueDataChannelNV", (void**)&cxrOpaqueDataState.xrReceiveOpaqueDataChannel},
        {"xrShutdownOpaqueDataChannelNV", (void**)&cxrOpaqueDataState.xrShutdownOpaqueDataChannel}
    };

    XrInstance instance = (XrInstance)xr_get_instance();

    // Load each function pointer using the map
    for (int i = 0; i < sizeof(function_map) / sizeof(function_map[0]); i++) {
        XrResult result = xrGetInstanceProcAddr(instance, function_map[i].name, (PFN_xrVoidFunction*)function_map[i].ptr);
        if (result != XR_SUCCESS) {
            return false;
        }
        if (*function_map[i].ptr == NULL) {
            return false;
        }
    }

    cxrOpaqueDataState.initialized = true;
    return true;
}

bool cxrOpaqueDataChannelCreate(const XrUuidEXT uuid) {
    if (!cxrOpaqueDataState.xrCreateOpaqueDataChannel) {
        lovrLog(LOG_WARN, "CloudXR", "cxrOpaqueDataChannelInit not successfully called before cxrOpaqueDataChannelCreate");
        return false;
    }

    if (cxrOpaqueDataState.opaqueDataChannel) {
        lovrLog(LOG_WARN, "CloudXR", "Opaque data channel already created");
        return false;
    }

    XrSystemId systemId = (XrSystemId)xr_get_system();
    XrInstance instance = (XrInstance)xr_get_instance();

    XrOpaqueDataChannelCreateInfoNV createInfo = {
        .type = XR_TYPE_OPAQUE_DATA_CHANNEL_CREATE_INFO_NV,
        .next = NULL,
        .systemId = systemId,
        .uuid = uuid
    };
    
    XrResult result = cxrOpaqueDataState.xrCreateOpaqueDataChannel(instance, &createInfo, &cxrOpaqueDataState.opaqueDataChannel);
    
    if (result != XR_SUCCESS) {
        return false;
    }

    lovrLog(LOG_INFO, "CloudXR", "Opaque data channel created: %p", cxrOpaqueDataState.opaqueDataChannel);
    cxrOpaqueDataState.uuid = uuid;
    return true;
}

bool cxrOpaqueDataChannelDestroy() {
    if (!cxrOpaqueDataState.xrDestroyOpaqueDataChannel) {
        lovrLog(LOG_WARN, "CloudXR", "cxrOpaqueDataChannelInit not successfully called before cxrOpaqueDataChannelDestroy");
        return false;
    }

    if (!cxrOpaqueDataState.opaqueDataChannel) {
        lovrLog(LOG_WARN, "CloudXR", "Opaque data channel not created");
        return false;
    }

    XrResult result = cxrOpaqueDataState.xrDestroyOpaqueDataChannel(cxrOpaqueDataState.opaqueDataChannel);
    if (result != XR_SUCCESS) {
        return false;
    }

    cxrOpaqueDataState.opaqueDataChannel = 0;
    cxrOpaqueDataState.uuid = (XrUuidEXT){0};
    return true;
}

XrOpaqueDataChannelStatusNV cxrOpaqueDataChannelGetState() {
    if (!cxrOpaqueDataState.opaqueDataChannel) {
        return XR_OPAQUE_DATA_CHANNEL_STATUS_MAX_ENUM;
    }

    XrOpaqueDataChannelStateNV state = {0};

    XrResult result = cxrOpaqueDataState.xrGetOpaqueDataChannelState(cxrOpaqueDataState.opaqueDataChannel, &state);
    if (result != XR_SUCCESS) {
        lovrLog(LOG_ERROR, "CloudXR", "Failed to get opaque data channel state: %d", result);
        return XR_OPAQUE_DATA_CHANNEL_STATUS_MAX_ENUM;
    }

    return state.state;
}

/**
 * Send opaque data using XR_NV_opaque_data_transport extension.
 * @param data Pointer to the data to send.
 * @param dataSize Number of bytes to send (<= XR_NV_OPAQUE_BUF_SIZE).
 * @return true on success, false on failure.
 */
bool cxrOpaqueDataChannelSend(const uint8_t* data, uint32_t dataSize) {
    if (cxrOpaqueDataChannelGetState() != XR_OPAQUE_DATA_CHANNEL_STATUS_CONNECTED_NV) {
        lovrLog(LOG_WARN, "CloudXR", "Opaque data channel not connected");
        return false;
    }

    if (!cxrOpaqueDataState.xrSendOpaqueDataChannel || !data || dataSize == 0 || dataSize > XR_NV_OPAQUE_BUF_SIZE) {
        return false;
    }

    XrResult result = cxrOpaqueDataState.xrSendOpaqueDataChannel(cxrOpaqueDataState.opaqueDataChannel, dataSize, data);
    return result == XR_SUCCESS;
}

bool cxrOpaqueDataChannelReceive(uint8_t* buffer, const uint32_t bufferSize, uint32_t* outDataSize) {
    if (cxrOpaqueDataChannelGetState() != XR_OPAQUE_DATA_CHANNEL_STATUS_CONNECTED_NV) {
        lovrLog(LOG_WARN, "CloudXR", "Opaque data channel not connected");
        return false;
    }

    if (!cxrOpaqueDataState.xrReceiveOpaqueDataChannel || !buffer || !outDataSize) {
        return false;
    }

    // xrReceiveOpaqueDataChannel employs the two call idiom where the first call is used to get the size of the data
    // and the second call is used to receive the data.
    uint32_t dataCount = 0;
    XrResult result = cxrOpaqueDataState.xrReceiveOpaqueDataChannel(cxrOpaqueDataState.opaqueDataChannel, 0, &dataCount, NULL);
    if (result != XR_SUCCESS) {
        return false;
    }

    if (dataCount == 0) {
        *outDataSize = 0;
        return true; // No data to receive
	}

    if (dataCount > bufferSize) {
        lovrLog(LOG_WARN, "CloudXR", "Buffer size is too small to receive data");
        return false;
    }

    result = cxrOpaqueDataState.xrReceiveOpaqueDataChannel(cxrOpaqueDataState.opaqueDataChannel, bufferSize, outDataSize, buffer);
    return result == XR_SUCCESS;
}

bool cxrOpaqueDataChannelShutdown() {
    if (!cxrOpaqueDataState.opaqueDataChannel) {
        // We make this method idempotent, so if it's already shut down / not created, treat as success
        return true;
    }

    if (!cxrOpaqueDataState.xrShutdownOpaqueDataChannel) {
        return false;
    }

    XrResult result = cxrOpaqueDataState.xrShutdownOpaqueDataChannel(cxrOpaqueDataState.opaqueDataChannel);
    cxrOpaqueDataState.opaqueDataChannel = 0;

    if (result != XR_SUCCESS && result != XR_ERROR_CHANNEL_NOT_CONNECTED_NV) {
        lovrLog(LOG_ERROR, "CloudXR", "Failed to shutdown opaque data channel: %d", result);
        return false;
    }

    return true;
}
