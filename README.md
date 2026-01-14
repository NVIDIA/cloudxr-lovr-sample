# NVIDIA CloudXR™ LÖVR Plugin

NVIDIA CloudXR™ provides seamless, high-fidelity XR streaming over any network. This plugin integrates CloudXR™ Runtime into LÖVR, a tiny, fast, open-source framework supporting multiple platforms and devices. Use this as a reference for integrating CloudXR™ into your own OpenXR applications.

## What is CloudXR™?

**CloudXR™** is NVIDIA's technology for streaming VR/AR applications over the network. Instead of rendering directly on the headset, your application runs on a workstation or in the cloud and streams the rendered frames through CloudXR™ to the headset over any network.

**LÖVR** is an open-source VR framework built on OpenXR. Think of it as an engine specifically designed for XR applications, with Lua as the scripting language.

## What This Plugin Does

This plugin provides three main capabilities:

1. **Runtime Management**: Automatically loads and configures the CloudXR™ service that handles wireless streaming
2. **Opaque Data Channels**: Optionally enable custom bidirectional communication between your LÖVR app and the headset for things like:
   - Sending application state updates
   - Receiving custom application data. Headset sensor data is automatically sent from headset clients
3. **Audio Streaming (Windows only)**: Supports streaming audio from server to headset on Windows platforms

**Key Point**: CloudXR™ replaces your standard OpenXR runtime, intercepting OpenXR calls and streaming the rendered frames to connected headsets over the network.

## Prerequisites

Before you begin, ensure you have:

- **CloudXR™ SDK**: Visit [cloudxr-sdk](https://catalog.ngc.nvidia.com/orgs/nvidia/collections/cloudxr-sdk) to download the CloudXR™ Runtime libraries and client software
- **Supported Headset**: 
  - **Apple Vision Pro** (fully supported)
  - **Meta Quest 3** (Early Access - requires separate application approval)
- **GPU**: NVIDIA GPU (recommended: NVIDIA RTX 6000 Ada)
- **Platform**: Windows or Linux (macOS not supported by CloudXR™)
- **Network**: High-speed WiFi connection (WiFi 6 recommended for best experience)
- **Build Tools**: CMake 3.10+, C compiler, git


## Building & Running

### Step 1: Download CloudXR™ Runtime Libraries

After obtaining CloudXR™ SDK access, download the CloudXR™ SDK archives for your platform and copy them to the root of the repository:

- **Linux**: Copy the Linux CloudXR SDK archive (e.g., `CloudXR-*-Linux-sdk.tar.gz`) to the repo root
- **Windows**: Copy the Windows CloudXR SDK archive (e.g., `CloudXR-*-Win64-sdk.zip`) to the repo root

**For convenience, the build scripts (`build.sh` for Linux, `build.bat` for Windows) will automatically:**
- Unpack the CloudXR SDK archives
- Copy libraries to `plugins/nvidia/lib/linux-x86_64/` or `plugins/nvidia/lib/windows-x86_64/`
- Copy header files to `plugins/nvidia/include/`
- Set up all required dependencies and runtime manifests

**Headset Client Software:** Download the CloudXR™ client for your headset from the CloudXR™ SDK package. For Apple Vision Pro, follow the installation instructions included with the SDK.

**Network Configuration:** For detailed networking requirements, including firewall configuration and port information, please refer to the [NVIDIA CloudXR™ SDK Documentation](https://docs.nvidia.com/cloudxr-sdk). This resource provides comprehensive guidance on network setup to ensure optimal streaming performance.

### Step 2: Build LÖVR with Plugin

This repository provides automated build scripts that fetch LÖVR and integrate the plugin:

```bash
# Linux - builds with upstream LOVR
./build.sh

# Windows (Note: keyboard should be set to US English, and terminal should NOT be run as administrator)
.\build.bat

# Or use a custom LOVR repository/branch
./build.sh --lovr-repo <url> --lovr-branch <branch>
```

The build script will:
- Clone LÖVR to `build/src/` with submodules
- Copy the CloudXR plugin into `build/src/plugins/`
- Build everything together

**Build options:**
```bash
./build.sh [options]

Options:
  --lovr-repo <url>       Custom LOVR repository
  --lovr-branch <branch>  Custom branch/tag
  Debug|Release           Build type (default: Debug)
  clean                   Clean build outputs
  cleanall                Clean everything including source

Examples:
  ./build.sh Release              # Release build
  ./build.sh cleanall && ./build.sh  # Clean rebuild
```

**What gets built:**
- `nvidia.dll` (Windows) or `nvidia.so` (Linux) - The CloudXR™ plugin
- CloudXR™ runtime libraries automatically copied to output directory
- Example applications ready to run

**Directory structure after build:**
```
cloudxr-lovr-plugin-sample/
├── plugins/nvidia/           # Plugin source
├── build/
│   ├── src/                  # LOVR with plugin integrated
│   │   └── plugins/nvidia/   # Plugin copied here
│   ├── Debug/                # Windows Debug build
│   ├── Release/              # Windows Release build
│   └── bin/                  # Linux build
```

### Step 3: Run the Example

The included example automatically configures everything for you:

```bash
# Linux
./run.sh

# Windows
run.bat

# Quest 3 (Early Access)
./run.sh --webrtc
run.bat --webrtc
```

**What happens automatically:**
- Sets `XR_RUNTIME_JSON` to point to CloudXR™ runtime json
- Loads CloudXR™ service before OpenXR initialization
- Configures the environment for wireless streaming

### Step 4: Verify It's Working

When running successfully, you should see output like this:

```
NVIDIA CloudXR Plugin Example
Loading CloudXR manager...
Loading NVIDIA CloudXR Runtime plugin...
NVIDIA CloudXR plugin loaded successfully
...
NVIDIA CloudXR plugin initialized
CloudXR Library API Version: 1.0.6
CloudXR Runtime Version: 6.0.1
...
CloudXR service started successfully
CloudXR Runtime initialized successfully
OpenXR extension procedures loaded successfully
Opaque data channel created: 0x013094f95000
Opaque data channel created successfully
```

**Next step:** Launch the CloudXR™ client on your compatible VR headset and connect to your workstation's IP address.

## How It Works

### Understanding the Architecture

CloudXR™ works by replacing your standard OpenXR runtime with a custom one that streams content over the network. Here's what happens:

1. **Your LÖVR app** renders VR content normally using OpenXR
2. **CloudXR™ Runtime** intercepts OpenXR calls and captures the rendered frames
3. **Network streaming** sends compressed frames to your headset
4. **Headset client** receives and displays the streamed content
5. **Headset client** sends poses and input back to CloudXR™ Runtime, which forwards them to your OpenXR app

### Key Components

**Two main libraries handle everything:**

| Library (Windows/Linux) | Purpose | What it does |
|---------|---------|--------------|
| `cloudxr.dll`/`libcloudxr.so` | Service Management | Starts/stops the CloudXR™ service, handles configuration |
| `openxr_cloudxr.dll`/`libopenxr_cloudxr.so` | OpenXR Interception | Replaces standard OpenXR runtime, streams frames to headset |

### Integration Steps

**For experienced developers integrating CloudXR™ into their own applications:**

1. **Set up OpenXR Loader**: Point `XR_RUNTIME_JSON` to CloudXR™ runtime json
2. **Load CloudXR™ service library**: Get function pointers from `cxrServiceAPI.h`. See `nvidia_cloudxr_runtime.c` for an example of loading the process addresses.
3. **Start service**: Create → Configure → Start the CloudXR™ service
4. **Initialize OpenXR**: Now OpenXR calls will be intercepted and streamed

**⚠️ Critical**: CloudXR™ service must start BEFORE any OpenXR calls, or initialization will fail.

**Example sequence:**
```c
// 1. Load library and get function pointers
// 2. Create service
nv_cxr_service_create(&service);

// 3. Configure (optional)
nv_cxr_service_set_string_property(service, "device-profile", "apple-vision-pro");

// 4. Start service
nv_cxr_service_start(service);

// 5. Now safe to call OpenXR functions
```


### Opaque Data Channels

**Opaque Data Channels** enable custom bidirectional communication between your LÖVR app and the headset. Think of it as a custom messaging system that works alongside the video stream.

**How it works:**
1. **Request extension**: Add `XR_NV_OPAQUE_DATA_CHANNEL_EXTENSION_NAME` to your OpenXR extensions
2. **Get function pointers**: Use `xrGetInstanceProcAddr` to get CloudXR™-specific functions from `XR_NV_opaque_data_channel.h`. See `cxrOpaqueDataChannelInit` as an example.
3. **Create channel**: Call `xrCreateOpaqueDataChannelNV` with a unique 16-byte UUID
4. **Wait for connection**: Poll `xrGetOpaqueDataChannelStateNV` until status is `CONNECTED`
5. **Send data**: Use `xrSendOpaqueDataChannelNV` to send bytes to the headset
6. **Receive data**: Poll `xrReceiveOpaqueDataChannelNV` to get data from the headset. See `cxrOpaqueDataChannelReceive` for implementation details.
7. **Cleanup**: Call `xrShutdownOpaqueDataChannelNV` when done

**Important**: Data size is limited to `XR_NV_OPAQUE_BUF_SIZE` bytes per message.

## LÖVR Integration

### Plugin Structure

```
plugins/nvidia/
├── CMakeLists.txt          # Build configuration
├── include/                # CloudXR™ Header files
├── src/                    # Source code
│   ├── nvidia_cloudxr_*.c  # Core CloudXR™ integration
│   └── l_nvidia_cloudxr.c  # Lua bindings
├── lib/                    # CloudXR™ runtime libraries
│   ├── linux-x86_64/       # Linux libraries
│   └── windows-x86_64/     # Windows libraries
└── examples/               # Example implementations
    └── cloudxr/            # CloudXR™ Lua project
```

### Using the Plugin in Your LÖVR App

**Step 1: Configure LÖVR**

In your `conf.lua`, disable the default headset module and set up CloudXR™:

```lua
function lovr.conf(t)
    -- Disable default headset since the plugin dynamically initializes it after CloudXR™ runtime has initialized.
    t.modules.headset = false
    
    -- Request CloudXR™ opaque data extension
    t.headset.extensions = {
        "XR_NVX1_opaque_data_channel" -- Corresponding to XR_NV_OPAQUE_DATA_CHANNEL_EXTENSION_NAME
    }
end
```

**Step 2: Load and Initialize CloudXR™**

```lua
-- Load the plugin
local success, nv_cxr = pcall(require, 'nvidia')
if not success then
    print("Failed to load CloudXR™ plugin")
    return
end

-- Initialize the runtime
nv_cxr.initRuntime()

-- Configure properties (optional)
nv_cxr.setRuntimeStringProperty("device-profile", "apple-vision-pro")

-- Start the service
nv_cxr.startRuntime()
```

**Step 3: Initialize OpenXR (after CloudXR™ is running)**

```lua
-- Now safe to initialize OpenXR
-- Note: HeadsetManager and CloudXRManager are helper modules from the example code
-- See plugins/nvidia/examples/cloudxr/ for full implementation
if not HeadsetManager.init() then
    print("Failed to initialize headset")
    return
end

-- Initialize opaque data channels after OpenXR
if not CloudXRManager.initOpaqueDataChannel() then
    print("Failed to initialize Opaque Data Channel")
    return
end
```

**Step 4: Use Opaque Data Channels**

```lua
function CloudXRManager.update()
...
    -- Check if channel is connected
    if nv_cxr.getOpaqueDataChannelState() == nv_cxr.OPAQUE_DATA_CHANNEL_STATUS.CONNECTED then
        -- Receive data from headset
        local data = nv_cxr.receiveOpaqueDataChannel()
        if data then
            print("Received from headset:", data)

            -- Echo the received data back to demonstrate bi-directional communication
            local success = nv_cxr.sendOpaqueDataChannel("Echo: " .. data)
        end
    end
...
```

In this example, we simply echo back the data the client sends, but data can be sent at any arbitrary point.

**Step 5: Cleanup**

```lua
-- When shutting down
nv_cxr.destroyRuntime()
```

## Quest 3 Early Access

CloudXR™ supports **Meta Quest 3** under Early Access. While Apple Vision Pro is fully supported, Quest 3 requires separate application approval.

**To apply for Early Access:**
1. Visit [developer.nvidia.com/cloudxr-sdk-early-access-program](https://developer.nvidia.com/cloudxr-sdk-early-access-program)
2. Complete the application form
3. Contact your NVIDIA Advisor if you have one

**Running with Quest 3**

Once accepted and configured, you can specify the device profile when starting the runtime:

```bash
# Use the --webrtc  flag
./run.sh --webrtc
run.bat --webrtc
```

## Troubleshooting

### Check the Runtime Logs

When the CloudXR™ runtime starts, it outputs the log file location. As an example:

```
logFile:   /tmp/com.nvidia.cloudxr_MxrYg9/cxr_server.2025-11-18T160550Z.log
```

Open this log file to diagnose runtime issues. Most CloudXR™ errors will be detailed here.

**Console Logging:** If you prefer runtime logs in the console instead of a file, set the environment variable:

```bash
export NV_CXR_FILE_LOGGING=false
```

Then run your application. Runtime logs will appear in the console output.

### Common Issues

| Problem | Diagnosis | Solution |
|---------|-----------|----------|
| **"Failed to load plugin"** | Plugin binary not found | Ensure LÖVR was built with plugin support |
| **"CloudXR™ service failed to start"** | Service initialization error | Check the runtime log file for specific errors. Verify CloudXR™ ports are open in your firewall |
| **"OpenXR runtime not found"** | Runtime JSON not set | Verify `XR_RUNTIME_JSON` environment variable points to `openxr_cloudxr.json` |
| **"Failed to start headset"** | LÖVR OpenXR initialization failed | Check the error message that follows. Verify OpenXR runtime is properly configured |
| **Headset won't connect** | Network or client issue | Ensure both devices are on the same network and CloudXR™ client is running |
| **Runtime lock file error** | See below | Previous runtime didn't exit cleanly |

### Runtime Lock File Error

If you see this error in the console or log file:

```
ERROR [start] Another instance of the runtime appears to be running (lock file exists at /run/user/361936563/runtime_started)
```

**Cause:** Either another CloudXR™ runtime is already running, or the previous LÖVR instance crashed prior to cleaning up the CloudXR™ runtime.

**Solution:** 
1. Check if another CloudXR™ application is running. If so, stop it first.
2. If no other runtime is running, delete the lock file:
   ```bash
   rm /run/user/361936563/runtime_started  # Use the path from your error message
   ```
3. Try running your application again.

### Linux Exit Segmentation Fault

On Linux, when exiting the application you may see an error like:

```
./run.sh: line 139: 225091 Segmentation fault      "./$(basename "$LOVR_BIN")" "$EXAMPLE_REL_PATH" $DEVICE_PROFILE
```

**Cause:** This is a known issue in the CloudXR™ Runtime during application shutdown.

**Impact:** This error occurs during cleanup and does not affect the functionality of the application while running. It can be safely ignored.

**Status:** This issue will be fixed in a future CloudXR™ Runtime release.

### Getting Help

- **LÖVR Issues**: [LÖVR Documentation](https://lovr.org/docs)
- **CloudXR™ Issues**: [NVIDIA CloudXR™ SDK](https://docs.nvidia.com/cloudxr-sdk) documentation
- **Plugin Issues**: Check the examples in this repository

## License

MIT, see [`LICENSE`](LICENSE) for details.

## Glossary

**CloudXR™**: NVIDIA's technology for streaming VR/AR applications over the network instead of rendering directly on the headset.

**LÖVR**: Open-source VR framework built on OpenXR, using Lua as the scripting language.

**OpenXR**: Cross-platform API standard for VR/AR applications, providing a common interface across different hardware.

**Runtime**: Software layer that manages VR/AR hardware and provides the OpenXR API implementation.

**Opaque Data Channels**: Custom communication channels that allow sending arbitrary data between your app and the headset.

**XR_RUNTIME_JSON**: Environment variable that tells the OpenXR loader which runtime to use.

**Headset Client**: Software running on the VR headset that receives and displays the streamed content.

**Service**: Background process that manages the CloudXR™ streaming functionality.

## Links

- **CloudXR Documentation**: [docs.nvidia.com/cloudxr-sdk](https://docs.nvidia.com/cloudxr-sdk/)
- **CloudXR SDK**: [catalog.ngc.nvidia.com/orgs/nvidia/collections/cloudxr-sdk](https://catalog.ngc.nvidia.com/orgs/nvidia/collections/cloudxr-sdk)
- **LÖVR (upstream)**: [github.com/bjornbytes/lovr](https://github.com/bjornbytes/lovr)
- **LÖVR Docs**: [lovr.org/docs](https://lovr.org/docs)


## Contributing

This project is not currently accepting external contributions.