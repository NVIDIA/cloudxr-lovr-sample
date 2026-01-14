// SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: MIT

#include "nvidia_cloudxr_runtime.h"
#include <headset/headset.h>
#include <util.h>

#define XR_NO_PROTOTYPES
#include <openxr/openxr.h>

#include <assert.h>
#include <string.h>

// Maximum lengths for security (prevent buffer over-read in strlen)
#define MAX_PROPERTY_NAME_LENGTH 256
#define MAX_PROPERTY_VALUE_LENGTH 4096

#ifdef _WIN32
#include <windows.h>
#define dlopen(name, flags) LoadLibraryA(name)
#define dlsym(handle, symbol) GetProcAddress(handle, symbol)
#define dlclose(handle) FreeLibrary(handle)
#define dlerror() "Windows DLL error"
#else
#include <dlfcn.h>
#endif

// Global plugin state
static CloudXRRuntimeState cxrRuntimeState = {0};

// Platform-specific library name
#ifdef _WIN32
static const char* library_name = "cloudxr.dll";
#elif defined(__linux__)
static const char* library_name = "libcloudxr.so";
#else
#error "Unsupported platform: CloudXR plugin only supports Windows and Linux"
#endif

bool cxrRuntimeInit() {
    if (cxrRuntimeState.initialized) {
        return true;
    }

    if (!cxrRuntimeLoadLibrary()) {
        lovrLog(LOG_ERROR, "CloudXR", "Failed to load library");
        return false;
    }

    if (!cxrRuntimeLoadFunctions()) {
        lovrLog(LOG_ERROR, "CloudXR", "Failed to load functions from library");
        dlclose(cxrRuntimeState.library);
        cxrRuntimeState.library = NULL;
        return false;
    }

	nv_cxr_result_t result = cxrRuntimeState.cxrServiceCreate(&cxrRuntimeState.service);
	if (result != NV_CXR_SUCCESS) {
		lovrLog(LOG_ERROR, "CloudXR", "Failed to create service (result: %d)", result);
		return false;
	}

    cxrRuntimeState.initialized = true;
    return true;
}

void cxrRuntimeDestroy() {
    if (cxrRuntimeState.service) {
        cxrRuntimeStopService();
    }

    if (cxrRuntimeState.library) {
        dlclose(cxrRuntimeState.library);
        cxrRuntimeState.library = NULL;
    }

    memset(&cxrRuntimeState, 0, sizeof(cxrRuntimeState));
}

bool cxrRuntimeLoadLibrary() {
    cxrRuntimeState.library = dlopen(library_name, RTLD_LAZY);
    if (!cxrRuntimeState.library) {
        return false;
    }
    return true;
}

bool cxrRuntimeLoadFunctions() {
    // Function name to function pointer mapping
    static const struct {
        const char* name;
        void** ptr;
    } function_map[] = {
        {"nv_cxr_get_library_api_version", (void**)&cxrRuntimeState.cxrGetLibraryApiVersion},
        {"nv_cxr_get_runtime_version", (void**)&cxrRuntimeState.cxrGetRuntimeVersion},
        {"nv_cxr_service_create", (void**)&cxrRuntimeState.cxrServiceCreate},
        {"nv_cxr_service_set_string_property", (void**)&cxrRuntimeState.cxrServiceSetStringProperty},
        {"nv_cxr_service_set_boolean_property", (void**)&cxrRuntimeState.cxrServiceSetBooleanProperty},
        {"nv_cxr_service_set_int64_property", (void**)&cxrRuntimeState.cxrServiceSetInt64Property},
        {"nv_cxr_service_get_string_property", (void**)&cxrRuntimeState.cxrServiceGetStringProperty},
        {"nv_cxr_service_get_boolean_property", (void**)&cxrRuntimeState.cxrServiceGetBooleanProperty},
        {"nv_cxr_service_get_int64_property", (void**)&cxrRuntimeState.cxrServiceGetInt64Property},
        {"nv_cxr_service_start", (void**)&cxrRuntimeState.cxrServiceStart},
        {"nv_cxr_service_stop", (void**)&cxrRuntimeState.cxrServiceStop},
        {"nv_cxr_service_join", (void**)&cxrRuntimeState.cxrServiceJoin},
        {"nv_cxr_service_destroy", (void**)&cxrRuntimeState.cxrServiceDestroy}
    };

    for (int i = 0; i < sizeof(function_map) / sizeof(function_map[0]); i++) {
        *function_map[i].ptr = dlsym(cxrRuntimeState.library, function_map[i].name);
        if (!*function_map[i].ptr) {
            return false;
        }
    }

    return true;
}

bool cxrRuntimeStartService() {
    if (!cxrRuntimeState.initialized) {
        lovrLog(LOG_ERROR, "CloudXR", "Cannot start service - not initialized");
        return false;
    }

    nv_cxr_result_t result = cxrRuntimeState.cxrServiceStart(cxrRuntimeState.service);
    if (result != NV_CXR_SUCCESS) {
        lovrLog(LOG_ERROR, "CloudXR", "Failed to start service (result: %d)", result);
        return false;
    }
    return true;
}

bool cxrRuntimeStopService() {
    if (!cxrRuntimeState.service) {
        return true;
    }

    nv_cxr_result_t result = cxrRuntimeState.cxrServiceStop(cxrRuntimeState.service);
    if (result != NV_CXR_SUCCESS) {
        lovrLog(LOG_ERROR, "CloudXR", "Failed to stop service (result: %d)", result);
        return false;
    }

    // Join the service
    result = cxrRuntimeState.cxrServiceJoin(cxrRuntimeState.service);
    if (result != NV_CXR_SUCCESS) {
        lovrLog(LOG_ERROR, "CloudXR", "Failed to join service (result: %d)", result);
        return false;
    }

    cxrRuntimeState.cxrServiceDestroy(cxrRuntimeState.service);
    cxrRuntimeState.service = NULL;
    return true;
}

bool cxrRuntimeGetLibraryApiVersion(uint32_t* major, uint32_t* minor, uint32_t* patch) {
    if (!cxrRuntimeState.initialized) {
        return false;
    }

    cxrRuntimeState.cxrGetLibraryApiVersion(major, minor, patch);
    return true;
}

bool cxrRuntimeGetRuntimeVersion(uint32_t* major, uint32_t* minor, uint32_t* patch) {
    if (!cxrRuntimeState.initialized) {
        return false;
    }

    cxrRuntimeState.cxrGetRuntimeVersion(major, minor, patch);
    return true;
}

bool cxrRuntimeSetStringProperty(const char* property_name, const char* value) {
    if (!cxrRuntimeIsInitialized()) {
        lovrLog(LOG_ERROR, "CloudXR", "Cannot set string property - not initialized or no service");
        return false;
    }

    nv_cxr_result_t result = cxrRuntimeState.cxrServiceSetStringProperty(
        cxrRuntimeState.service, 
        property_name, 
        strnlen(property_name, MAX_PROPERTY_NAME_LENGTH), 
        value, 
        strnlen(value, MAX_PROPERTY_VALUE_LENGTH)
    );
    
    if (result != NV_CXR_SUCCESS) {
        lovrLog(LOG_ERROR, "CloudXR", "Failed to set string property '%s' (result: %d)", property_name, result);
        return false;
    }
    return true;
}

bool cxrRuntimeSetBooleanProperty(const char* property_name, bool value) {
    if (!cxrRuntimeIsInitialized()) {
        lovrLog(LOG_ERROR, "CloudXR", "Cannot set boolean property - not initialized or no service");
        return false;
    }

    nv_cxr_result_t result = cxrRuntimeState.cxrServiceSetBooleanProperty(
        cxrRuntimeState.service, 
        property_name, 
        strnlen(property_name, MAX_PROPERTY_NAME_LENGTH), 
        value
    );
    
    if (result != NV_CXR_SUCCESS) {
        lovrLog(LOG_ERROR, "CloudXR", "Failed to set boolean property '%s' (result: %d)", property_name, result);
        return false;
    }
    return true;
}

bool cxrRuntimeSetInt64Property(const char* property_name, int64_t value) {
    if (!cxrRuntimeIsInitialized()) {
        lovrLog(LOG_ERROR, "CloudXR", "Cannot set int64 property - not initialized or no service");
        return false;
    }

    nv_cxr_result_t result = cxrRuntimeState.cxrServiceSetInt64Property(
        cxrRuntimeState.service, 
        property_name, 
        strnlen(property_name, MAX_PROPERTY_NAME_LENGTH), 
        value
    );
    
    if (result != NV_CXR_SUCCESS) {
        lovrLog(LOG_ERROR, "CloudXR", "Failed to set int64 property '%s' (result: %d)", property_name, result);
        return false;
    }
    return true;
}

bool cxrRuntimeGetStringProperty(const char* property_name, char* value, size_t* value_length) {
    if (!cxrRuntimeIsInitialized()) {
        lovrLog(LOG_ERROR, "CloudXR", "Cannot get string property - not initialized or no service");
        return false;
    }

    nv_cxr_result_t result = cxrRuntimeState.cxrServiceGetStringProperty(
        cxrRuntimeState.service, 
        property_name, 
        strnlen(property_name, MAX_PROPERTY_NAME_LENGTH), 
        value, 
        value_length
    );
    
    if (result != NV_CXR_SUCCESS) {
        lovrLog(LOG_ERROR, "CloudXR", "Failed to get string property '%s' (result: %d)", property_name, result);
        return false;
    }
    return true;
}

bool cxrRuntimeGetBooleanProperty(const char* property_name, bool* value) {
    if (!cxrRuntimeIsInitialized()) {
        lovrLog(LOG_ERROR, "CloudXR", "Cannot get boolean property - not initialized or no service");
        return false;
    }

    nv_cxr_result_t result = cxrRuntimeState.cxrServiceGetBooleanProperty(
        cxrRuntimeState.service, 
        property_name, 
        strnlen(property_name, MAX_PROPERTY_NAME_LENGTH), 
        value
    );
    
    if (result != NV_CXR_SUCCESS) {
        lovrLog(LOG_ERROR, "CloudXR", "Failed to get boolean property '%s' (result: %d)", property_name, result);
        return false;
    }
    return true;
}

bool cxrRuntimeGetInt64Property(const char* property_name, int64_t* value) {
    if (!cxrRuntimeIsInitialized()) {
        lovrLog(LOG_ERROR, "CloudXR", "Cannot get int64 property - not initialized or no service");
        return false;
    }

    nv_cxr_result_t result = cxrRuntimeState.cxrServiceGetInt64Property(
        cxrRuntimeState.service, 
        property_name, 
        strnlen(property_name, MAX_PROPERTY_NAME_LENGTH), 
        value
    );
    
    if (result != NV_CXR_SUCCESS) {
        lovrLog(LOG_ERROR, "CloudXR", "Failed to get int64 property '%s' (result: %d)", property_name, result);
        return false;
    }
    return true;
}

bool cxrRuntimeIsInitialized() {
    return cxrRuntimeState.initialized && cxrRuntimeState.service != NULL;
}