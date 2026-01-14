// SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: MIT

#ifndef LOVR_NVIDIA_CLOUDXR_RUNTIME_H
#define LOVR_NVIDIA_CLOUDXR_RUNTIME_H

#include <stdbool.h>
#include "cxrServiceAPI.h"

#ifdef __cplusplus
extern "C" {
#endif

// Plugin state
typedef struct {
    void* library;
    struct nv_cxr_service* service;
    bool initialized;
    
    // Function pointers loaded from the library
    PFN_nv_cxr_get_library_api_version cxrGetLibraryApiVersion;
    PFN_nv_cxr_get_runtime_version cxrGetRuntimeVersion;
    PFN_nv_cxr_service_create cxrServiceCreate;
    PFN_nv_cxr_service_set_string_property cxrServiceSetStringProperty;
    PFN_nv_cxr_service_set_boolean_property cxrServiceSetBooleanProperty;
    PFN_nv_cxr_service_set_int64_property cxrServiceSetInt64Property;
    PFN_nv_cxr_service_get_string_property cxrServiceGetStringProperty;
    PFN_nv_cxr_service_get_boolean_property cxrServiceGetBooleanProperty;
    PFN_nv_cxr_service_get_int64_property cxrServiceGetInt64Property;
    PFN_nv_cxr_service_start cxrServiceStart;
    PFN_nv_cxr_service_stop cxrServiceStop;
    PFN_nv_cxr_service_join cxrServiceJoin;
    PFN_nv_cxr_service_destroy cxrServiceDestroy;
} CloudXRRuntimeState;

// Plugin API functions
bool cxrRuntimeInit();
void cxrRuntimeDestroy();
bool cxrRuntimeLoadLibrary();
bool cxrRuntimeLoadFunctions();
bool cxrRuntimeStartService();
bool cxrRuntimeStopService();
bool cxrRuntimeGetLibraryApiVersion(uint32_t* major, uint32_t* minor, uint32_t* patch);
bool cxrRuntimeGetRuntimeVersion(uint32_t* major, uint32_t* minor, uint32_t* patch);

// Property setting functions
bool cxrRuntimeSetStringProperty(const char* propertyName, const char* value);
bool cxrRuntimeSetBooleanProperty(const char* propertyName, bool value);
bool cxrRuntimeSetInt64Property(const char* propertyName, int64_t value);

// Property getting functions
bool cxrRuntimeGetStringProperty(const char* propertyName, char* value, size_t* valueLength);
bool cxrRuntimeGetBooleanProperty(const char* propertyName, bool* value);
bool cxrRuntimeGetInt64Property(const char* propertyName, int64_t* value);

// Utility functions
bool cxrRuntimeIsInitialized();

#ifdef __cplusplus
}
#endif

#endif // LOVR_NVIDIA_CLOUDXR_RUNTIME_H 