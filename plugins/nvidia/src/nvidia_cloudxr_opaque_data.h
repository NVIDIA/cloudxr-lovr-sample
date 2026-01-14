// SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: MIT

#ifndef LOVR_NVIDIA_CLOUDXR_OPAQUE_DATA_H
#define LOVR_NVIDIA_CLOUDXR_OPAQUE_DATA_H

#include <stdbool.h>
#include "cxrServiceAPI.h"
#include "openxr/XR_NV_opaque_data_channel.h"

#define XR_NV_OPAQUE_BUF_SIZE 900

#ifdef __cplusplus
extern "C" {
#endif

// Plugin state
typedef struct {
    // OpenXR function pointers for Nvidia CloudXR Opaque Data Transport
    PFN_xrCreateOpaqueDataChannelNV xrCreateOpaqueDataChannel;
    PFN_xrDestroyOpaqueDataChannelNV xrDestroyOpaqueDataChannel;
    PFN_xrGetOpaqueDataChannelStateNV xrGetOpaqueDataChannelState;
    PFN_xrSendOpaqueDataChannelNV xrSendOpaqueDataChannel;
    PFN_xrReceiveOpaqueDataChannelNV xrReceiveOpaqueDataChannel;
    PFN_xrShutdownOpaqueDataChannelNV xrShutdownOpaqueDataChannel;

    XrOpaqueDataChannelNV opaqueDataChannel;
    XrUuidEXT uuid;
    bool initialized;
} CloudXROpaqueDataState;

// Opaque Data Transport functions
bool cxrOpaqueDataChannelInit();

bool cxrOpaqueDataChannelCreate(const XrUuidEXT uuid);
bool cxrOpaqueDataChannelDestroy();
// Returns the state of the opaque data channel state.
// Returns XR_OPAQUE_DATA_CHANNEL_STATUS_MAX_ENUM if there is an issue retrieving the state.
XrOpaqueDataChannelStatusNV cxrOpaqueDataChannelGetState();
bool cxrOpaqueDataChannelSend(const uint8_t* data, uint32_t dataSize);
bool cxrOpaqueDataChannelReceive(uint8_t* buffer, const uint32_t bufferSize, uint32_t* outDataSize);
bool cxrOpaqueDataChannelShutdown();

#ifdef __cplusplus
}
#endif

#endif // LOVR_NVIDIA_CLOUDXR_OPAQUE_DATA_H 