// SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: MIT

#include "nvidia_cloudxr_runtime.h"
#include "nvidia_cloudxr_opaque_data.h"
#include "util.h"
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

// Lua uses double-precision floating point for numbers, which has 53 bits of precision
// for integers. Values outside this range may lose precision when converted.
#define LUA_MAX_SAFE_INTEGER_BITS 53

// Define safe integer bounds for Lua
#define LUA_MAX_SAFE_INTEGER ((int64_t)((1LL << LUA_MAX_SAFE_INTEGER_BITS) - 1))
#define LUA_MIN_SAFE_INTEGER ((int64_t)(-(1LL << LUA_MAX_SAFE_INTEGER_BITS)))

// Lua binding functions
static int l_cxr_runtime_init(lua_State* L) {
    bool success = cxrRuntimeInit();
    lua_pushboolean(L, success);
    return 1;
}

static int l_cxr_runtime_destroy(lua_State* L) {
    cxrRuntimeDestroy();
    return 0;
}

static int l_cxr_runtime_start_service(lua_State* L) {
    bool success = cxrRuntimeStartService();
    lua_pushboolean(L, success);
    return 1;
}

static int l_cxr_runtime_stop_service(lua_State* L) {
    bool success = cxrRuntimeStopService();
    lua_pushboolean(L, success);
    return 1;
}

static int l_cxr_runtime_get_library_api_version(lua_State* L) {
    uint32_t major, minor, patch;
    bool success = cxrRuntimeGetLibraryApiVersion(&major, &minor, &patch);

    if (success) {
        lua_pushnumber(L, major);
        lua_pushnumber(L, minor);
        lua_pushnumber(L, patch);
        return 3;
    }
    else {
        lua_pushnil(L);
        return 1;
    }
}

static int l_cxr_runtime_get_runtime_version(lua_State* L) {
    uint32_t major, minor, patch;
    bool success = cxrRuntimeGetRuntimeVersion(&major, &minor, &patch);
    
    if (success) {
        lua_pushnumber(L, major);
        lua_pushnumber(L, minor);
        lua_pushnumber(L, patch);
        return 3;
    } else {
        lua_pushnil(L);
        return 1;
    }
}

static int l_cxr_runtime_load_library(lua_State* L) {
    bool success = cxrRuntimeLoadLibrary();
    lua_pushboolean(L, success);
    return 1;
}

static int l_cxr_runtime_load_functions(lua_State* L) {
    bool success = cxrRuntimeLoadFunctions();
    lua_pushboolean(L, success);
    return 1;
}

static int l_cxr_runtime_set_string_property(lua_State* L) {
    // Check if we have a service and it's initialized
    if (!cxrRuntimeIsInitialized()) {
        lua_pushboolean(L, false);
        return 1;
    }
    
    // Get parameters: property_name, value
    const char* property_name = luaL_checkstring(L, 1);
    const char* value = luaL_checkstring(L, 2);
    
    // Call the C function to set the property
    bool success = cxrRuntimeSetStringProperty(property_name, value);
    lua_pushboolean(L, success);
    return 1;
}

static int l_cxr_runtime_set_boolean_property(lua_State* L) {
    // Check if we have a service and it's initialized
    if (!cxrRuntimeIsInitialized()) {
        lua_pushboolean(L, false);
        return 1;
    }
    
    // Get parameters: property_name (string), value (boolean)
    const char* property_name = luaL_checkstring(L, 1);
    bool value = lua_toboolean(L, 2);
    
    // Call the C function to set the property
    bool success = cxrRuntimeSetBooleanProperty(property_name, value);
    lua_pushboolean(L, success);
    return 1;
}

static int l_cxr_runtime_set_int64_property(lua_State* L) {
    // Check if we have a service and it's initialized
    if (!cxrRuntimeIsInitialized()) {
        lua_pushboolean(L, false);
        return 1;
    }
    
    // Get parameters: property_name (string), value (number)
    const char* property_name = luaL_checkstring(L, 1);
    int64_t value = (int64_t)luaL_checknumber(L, 2);
    
    // Call the C function to set the property
    bool success = cxrRuntimeSetInt64Property(property_name, value);
    lua_pushboolean(L, success);
    return 1;
}

static int l_cxr_runtime_get_string_property(lua_State* L) {
    // Check if we have a service and it's initialized
    if (!cxrRuntimeIsInitialized()) {
        lua_pushnil(L);
        return 1;
    }
    
    // Get parameters: property_name (string)
    const char* property_name = luaL_checkstring(L, 1);
    
    // Buffer to receive the property value
    char buffer[1024];  // Reasonable buffer size for string properties
    size_t value_length = sizeof(buffer);
    
    // Call the C function to get the property
    bool success = cxrRuntimeGetStringProperty(property_name, buffer, &value_length);
    
    if (success && value_length > 0) {
        // Create a Lua string from the received data
        lua_pushlstring(L, buffer, value_length);
    } else if (!success && value_length > 1024) {
        // Buffer was too small, need to allocate on heap
        char* heap_buffer = (char*)lua_newuserdata(L, value_length + 1); // +1 for null terminator
        if (!heap_buffer) {
            lovrLog(LOG_ERROR, "CloudXR", "Failed to allocate memory for string property");
            lua_pushnil(L);
            return 1;
        }
        
        // Second call: get the actual string value with heap buffer
        success = cxrRuntimeGetStringProperty(property_name, heap_buffer, &value_length);
        
        if (success && value_length > 0) {
            // Ensure null termination
            heap_buffer[value_length] = '\0';
            // Create a Lua string from the received data
            lua_pushlstring(L, heap_buffer, value_length);
            // Remove the userdata from stack (Lua will handle cleanup)
            lua_remove(L, -2);
        } else {
            lovrLog(LOG_ERROR, "CloudXR", "Failed to get string property on heap '%s' (result: %d)", property_name, success);
            // Remove the userdata from stack (Lua will handle cleanup)
            lua_remove(L, -1);
            lua_pushnil(L);
        }
    } else {
        lovrLog(LOG_ERROR, "CloudXR", "Failed to get string property '%s' (result: %d)", property_name, success);
        lua_pushnil(L);
    }
    
    return 1;
}

static int l_cxr_runtime_get_boolean_property(lua_State* L) {
    // Check if we have a service and it's initialized
    if (!cxrRuntimeIsInitialized()) {
        lua_pushnil(L);
        return 1;
    }
    
    // Get parameters: property_name (string)
    const char* property_name = luaL_checkstring(L, 1);
    
    // Variable to receive the property value
    bool value;
    
    // Call the C function to get the property
    bool success = cxrRuntimeGetBooleanProperty(property_name, &value);
    
    if (success) {
        lua_pushboolean(L, value);
    } else {
        lua_pushnil(L);
    }
    return 1;
}

static int l_cxr_runtime_get_int64_property(lua_State* L) {
    // Check if we have a service and it's initialized
    if (!cxrRuntimeIsInitialized()) {
        lua_pushnil(L);
        return 1;
    }
    
    // Get parameters: property_name (string)
    const char* property_name = luaL_checkstring(L, 1);
    
    // Variable to receive the property value
    int64_t value;
    
    // Call the C function to get the property
    bool success = cxrRuntimeGetInt64Property(property_name, &value);
    
    if (success) {
        if (value >= LUA_MIN_SAFE_INTEGER && value <= LUA_MAX_SAFE_INTEGER) {
            lua_pushnumber(L, (lua_Number)value);
        } else {
            lua_pushnil(L);
        }
    } else {
        lua_pushnil(L);
    }
    return 1;
}

/* Opaque Data Channel */

static int l_cxr_opaque_data_channel_init(lua_State* L) {
    // Call the C function to load extension functions
    bool success = cxrOpaqueDataChannelInit();
    lua_pushboolean(L, success);
    return 1;
}

static int l_cxr_opaque_data_channel_create(lua_State* L) {
    // Call the C function to create the opaque data channel
    // Check if first parameter is a table
    if (!lua_istable(L, 1)) {
        luaL_error(L, "First parameter must be a table containing 16 UUID bytes");
        return 0;
    }
    
    // Get UUID array from Lua (16 bytes)
    XrUuidEXT uuid;
    for (int i = 0; i < 16; i++) {
        lua_pushinteger(L, i + 1);  // Lua arrays are 1-indexed
        lua_gettable(L, 1);         // Get table[i+1] from the first parameter
        if (!lua_isnumber(L, -1)) {
            luaL_error(L, "UUID array element %d must be a number", i + 1);
        }
        uuid.data[i] = (uint8_t)lua_tointeger(L, -1);
        lua_pop(L, 1);  // Remove the value from stack
    }
    
    bool success = cxrOpaqueDataChannelCreate(uuid);
    lua_pushboolean(L, success);
    return 1;
}

static int l_cxr_opaque_data_channel_destroy(lua_State* L) {
    // Call the C function to destroy the opaque data channel
    bool success = cxrOpaqueDataChannelDestroy();
    lua_pushboolean(L, success);
    return 1;
}

static int l_cxr_opaque_data_channel_get_state(lua_State* L) {
    XrOpaqueDataChannelStatusNV state = cxrOpaqueDataChannelGetState();    
    // Push the C enum value directly - no conversion needed!
    lua_pushinteger(L, state);
    return 1;
}

static int l_cxr_opaque_data_channel_send(lua_State* L) { 
    // Get parameters: data (string)
    const char* data = luaL_checkstring(L, 1);
    size_t dataSize = strnlen(data, XR_NV_OPAQUE_BUF_SIZE + 1);
    
    // Check if data size is within limits
    if (dataSize > XR_NV_OPAQUE_BUF_SIZE) {
        lua_pushboolean(L, false);
        return 1;
    }
    
    // Call the C function to send the data
    bool success = cxrOpaqueDataChannelSend((const uint8_t*)data, (uint32_t)dataSize);
    lua_pushboolean(L, success);
    return 1;
}

static int l_cxr_opaque_data_channel_receive(lua_State* L) {    
    // Buffer to receive data
    uint8_t buffer[XR_NV_OPAQUE_BUF_SIZE];
    uint32_t outDataSize = 0;
    
    // Call the C function to receive data
    bool success = cxrOpaqueDataChannelReceive(buffer, XR_NV_OPAQUE_BUF_SIZE, &outDataSize);
    
    if (success && outDataSize > 0) {
        // Create a Lua string from the received data
        lua_pushlstring(L, (const char*)buffer, outDataSize);
        return 1;
    } else {
        lua_pushnil(L);
        return 1;
    }
}

static int l_cxr_opaque_data_channel_shutdown(lua_State* L) {
    // Call the C function to shutdown the opaque data channel
    bool success = cxrOpaqueDataChannelShutdown();
    lua_pushboolean(L, success);
    return 1;
}

// Function table for the module
static const luaL_Reg lovr_nv_cxr_functions[] = {
    /* Runtime */
    { "initRuntime", l_cxr_runtime_init },
    { "destroyRuntime", l_cxr_runtime_destroy },
    { "startRuntime", l_cxr_runtime_start_service },
    { "stopRuntime", l_cxr_runtime_stop_service },
    { "getRuntimeLibraryApiVersion", l_cxr_runtime_get_library_api_version },
    { "getRuntimeVersion", l_cxr_runtime_get_runtime_version },
    { "loadRuntimeLibrary", l_cxr_runtime_load_library },
    { "loadRuntimeFunctions", l_cxr_runtime_load_functions },
    { "setRuntimeStringProperty", l_cxr_runtime_set_string_property },
    { "setRuntimeBooleanProperty", l_cxr_runtime_set_boolean_property },
    { "setRuntimeInt64Property", l_cxr_runtime_set_int64_property },
    { "getRuntimeStringProperty", l_cxr_runtime_get_string_property },
    { "getRuntimeBooleanProperty", l_cxr_runtime_get_boolean_property },
    { "getRuntimeInt64Property", l_cxr_runtime_get_int64_property },
    
    /* Opaque Data Channel */
    { "initOpaqueDataChannel", l_cxr_opaque_data_channel_init },
    { "createOpaqueDataChannel", l_cxr_opaque_data_channel_create },
    { "destroyOpaqueDataChannel", l_cxr_opaque_data_channel_destroy },
    { "getOpaqueDataChannelState", l_cxr_opaque_data_channel_get_state },
    { "sendOpaqueDataChannel", l_cxr_opaque_data_channel_send },
    { "receiveOpaqueDataChannel", l_cxr_opaque_data_channel_receive },
    { "shutdownOpaqueDataChannel", l_cxr_opaque_data_channel_shutdown },
    { NULL, NULL }
};

// Function to register enum constants
static void register_enum_constants(lua_State* L) {
    // Opaque Data Channel Status constants
    lua_pushstring(L, "OPAQUE_DATA_CHANNEL_STATUS");
    lua_newtable(L);
    
    lua_pushstring(L, "CONNECTING");
    lua_pushinteger(L, XR_OPAQUE_DATA_CHANNEL_STATUS_CONNECTING_NV);
    lua_settable(L, -3);
    
    lua_pushstring(L, "CONNECTED");
    lua_pushinteger(L, XR_OPAQUE_DATA_CHANNEL_STATUS_CONNECTED_NV);
    lua_settable(L, -3);

    lua_pushstring(L, "SHUTTING");
    lua_pushinteger(L, XR_OPAQUE_DATA_CHANNEL_STATUS_SHUTTING_NV);
    lua_settable(L, -3);
    
    lua_pushstring(L, "DISCONNECTED");
    lua_pushinteger(L, XR_OPAQUE_DATA_CHANNEL_STATUS_DISCONNECTED_NV);
    lua_settable(L, -3);
    
    lua_pushstring(L, "MAX_ENUM");
    lua_pushinteger(L, XR_OPAQUE_DATA_CHANNEL_STATUS_MAX_ENUM);
    lua_settable(L, -3);
    
    lua_settable(L, -3);  // Set OPAQUE_DATA_CHANNEL_STATUS table in module
}

// Module loader function
#ifdef _WIN32
#define NVIDIA_EXPORT __declspec(dllexport)
#else
#define NVIDIA_EXPORT __attribute__((visibility("default")))
#endif

NVIDIA_EXPORT
int luaopen_nvidia(lua_State* L) {
    // Create the module table
    lua_newtable(L);
    
    // Register all functions
    luaL_setfuncs(L, lovr_nv_cxr_functions, 0);
    
    // Register enum constants
    register_enum_constants(L);
    
    return 1;
}