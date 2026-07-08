# NVIDIA CloudXR™ LÖVR Plugin

NVIDIA CloudXR™ provides seamless, high-fidelity XR streaming over any network. This plugin integrates the CloudXR™ Runtime into LÖVR, a tiny, fast, open-source framework for OpenXR applications. Use it as a reference for integrating CloudXR™ into your own OpenXR apps.

- **CloudXR™** streams VR/AR rendering from a workstation or the cloud to the headset over the network instead of rendering on the headset.
- **LÖVR** is an open-source XR engine built on OpenXR with Lua as the scripting language.

This plugin gives a LÖVR app three things:

1. **Runtime management** — automatically loads and configures the CloudXR™ service that handles wireless streaming.
2. **Opaque data channels** — optional bidirectional custom messaging between the app and the headset (app state, sensor data, etc.).
3. **Audio streaming (Windows only)** — server-to-headset audio streaming.

> **Key point:** CloudXR™ replaces the standard OpenXR runtime. It intercepts OpenXR calls and streams the rendered frames to a connected headset.

---

## Quick Start (novice users)

This is the fast path. Follow it once and you'll have the sample running. For everything else (custom LÖVR commits, alternate device profiles, custom CloudXR.js builds, etc.) see [Advanced Configuration](#advanced-configuration).

### Prerequisites

- **OS**: Windows or Linux (macOS is not supported by CloudXR™).
- **GPU**: NVIDIA GPU (NVIDIA RTX 6000 Ada recommended).
- **Headset**: Apple Vision Pro (uses native CloudXR™ client), or Meta Quest 2/3/3S / PICO 4 Ultra (use [CloudXR.js](https://docs.nvidia.com/cloudxr-sdk/latest/usr_guide/cloudxr_js/index.html) in the headset browser). PICO 4 Ultra requires HTTPS and needs you to bring your own CloudXR.js server — see [CloudXR.js configuration](#cloudxrjs-configuration).
- **Network**: High-speed Wi-Fi (Wi-Fi 6 recommended), with the headset and workstation on the same network.
- **Build tools**: CMake 3.10+, C/C++ compiler, `git`, `curl`.
- **Node.js v20.19.0 or later with npm** — automatically used by the build to set up the CloudXR.js sample. Install it manually first if your system doesn't have it, or pass `--without-cloudxrjs` to skip the CloudXR.js sample setup entirely.

The build scripts download the CloudXR™ Runtime SDK and CloudXR.js package from NVIDIA NGC the first time they run. To use specific versions, see [Use a specific CloudXR Runtime / CloudXR.js version](#use-a-specific-cloudxr-runtime--cloudxrjs-version).

### Apple Vision Pro

```bash
# Linux
./build.sh && ./run.sh

# Windows (US English keyboard, terminal NOT run as admin)
.\build.bat && .\run.bat
```

Then launch the native CloudXR™ client on Apple Vision Pro and connect to your workstation.

### Meta Quest 2/3/3S (CloudXR.js over WebRTC)

```bash
# Linux
./build.sh && ./run.sh --device-profile=auto-webrtc

# Windows (US English keyboard, terminal NOT run as admin)
# Quote the profile arg so cmd.exe doesn't split on the '='.
.\build.bat && .\run.bat "--device-profile=auto-webrtc"
```

> **PICO 4 Ultra users:** skip the steps below — the PICO browser doesn't accept the insecure-origin workaround used here, so it requires HTTPS. Bring your own HTTPS CloudXR.js server and pass `--without-cloudxrjs`; see the **HTTPS mode** bullet in [CloudXR.js configuration](#cloudxrjs-configuration).

`run.sh`/`run.bat` automatically starts the CloudXR.js dev server on port 8080 when `--device-profile=auto-webrtc` is used. Then on the Quest:

1. Open the Meta Quest browser and navigate to `http://<your-workstation-ip>:8080/`.
2. **Configure the browser to allow insecure origins** so the page can use the WebXR API over HTTP. See [the CloudXR.js client setup guide](https://docs.nvidia.com/cloudxr-sdk/latest/usr_guide/cloudxr_js/client_setup.html#meta-quest-configuration) for the exact `chrome://flags/unsafely-treat-insecure-origin-as-secure` steps.
3. Press **Connect** in the page to start streaming.

> **Note:** The dev server runs over HTTP for the simplest local setup. For HTTPS, an existing CloudXR.js server on port 8080, or `--without-cloudxrjs`, see [CloudXR.js configuration](#cloudxrjs-configuration).

### Verify it's working

A successful launch ends with these key messages (with other lines interleaved):

```text
NVIDIA CloudXR Plugin Example
Loading CloudXR manager...

Loading NVIDIA CloudXR Runtime plugin...
NVIDIA CloudXR plugin loaded successfully
 INFO [logServiceInfo] Created CloudXR™ Service
	version: <RUNTIME VETRSION>
	tag: <RUNTIME VETRSION>
    ...
	uses: Monado™
NVIDIA CloudXR plugin initialized
CloudXR Library API Version: <API VERSION>
CloudXR Runtime Version: <RUNTIME VETRSION>
CloudXR device profile:	<DEVICE PROFILE>
...
CloudXR Runtime initialized successfully

```

If the headset doesn't connect, jump to [Troubleshooting](#troubleshooting).

---

## How It Works

### Architecture

CloudXR™ replaces the standard OpenXR runtime with a custom one that streams content over the network:

1. **Your LÖVR app** renders VR content normally using OpenXR.
2. **CloudXR™ Runtime** intercepts OpenXR calls and captures the rendered frames.
3. **Network streaming** sends compressed frames to the headset.
4. **Headset client** receives and displays the streamed content.
5. **Headset client** sends poses and input back, which CloudXR™ Runtime forwards to the OpenXR app.

### Key components

| Library (Windows / Linux) | Purpose | What it does |
|---|---|---|
| `cloudxr.dll` / `libcloudxr.so` | Service management | Starts/stops the CloudXR™ service, handles configuration |
| `openxr_cloudxr.dll` / `libopenxr_cloudxr.so` | OpenXR interception | Replaces the standard OpenXR runtime, streams frames to the headset |

### Integration outline

For developers integrating CloudXR™ into their own OpenXR application:

1. **Set `XR_RUNTIME_JSON`** to the CloudXR™ runtime manifest.
2. **Load the CloudXR™ service library** and resolve function pointers from `cxrServiceAPI.h`. See `nvidia_cloudxr_runtime.c` for an example.
3. **Start the service**: Create → Configure → Start the CloudXR™ service.
4. **Initialize OpenXR.** OpenXR calls are now intercepted and streamed.

> **Critical:** the CloudXR™ service must start **before** any OpenXR calls, or initialization will fail.

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

Opaque Data Channels enable custom bidirectional communication between the app and the headset alongside the video stream.

1. **Request the extension**: add `XR_NV_OPAQUE_DATA_CHANNEL_EXTENSION_NAME` to your OpenXR extensions.
2. **Get function pointers**: use `xrGetInstanceProcAddr` to resolve the CloudXR™ functions from `XR_NV_opaque_data_channel.h` (see `cxrOpaqueDataChannelInit`).
3. **Create a channel** with `xrCreateOpaqueDataChannelNV` and a unique 16-byte UUID.
4. **Wait for connection**: poll `xrGetOpaqueDataChannelStateNV` until status is `CONNECTED`.
5. **Send/receive** with `xrSendOpaqueDataChannelNV` / `xrReceiveOpaqueDataChannelNV` (see `cxrOpaqueDataChannelReceive`).
6. **Cleanup** with `xrShutdownOpaqueDataChannelNV`.

> Per-message size is limited to `XR_NV_OPAQUE_BUF_SIZE` bytes.

---

## LÖVR Integration

### Plugin layout

```text
plugins/nvidia/
├── CMakeLists.txt          # Build configuration (reads CLOUDXR_INCLUDE_PATH / CLOUDXR_LIB_PATH)
├── src/                    # Source code
│   ├── nvidia_cloudxr_*.c  # Core CloudXR™ integration
│   └── l_nvidia_cloudxr.c  # Lua bindings
└── examples/               # Example implementations
    └── cloudxr/            # CloudXR™ Lua project
```

The CloudXR SDK is not vendored. The build scripts extract it to `build/cloudxr/CloudXR-*-sdk/` and pass include / library paths to CMake. For the full layout including build outputs and cached archives, see [Project layout after a build](#project-layout-after-a-build) in Advanced Configuration.

### Using the plugin in your LÖVR app

**Step 1 — Configure LÖVR** in `conf.lua`:

```lua
function lovr.conf(t)
    -- Disable the default headset module since the plugin initializes it after CloudXR™ is up.
    t.modules.headset = false

    -- Request the CloudXR™ opaque data extension
    t.headset.extensions = {
        "XR_NVX1_opaque_data_channel" -- Corresponds to XR_NV_OPAQUE_DATA_CHANNEL_EXTENSION_NAME
    }
end
```

**Step 2 — Load and start CloudXR™:**

```lua
local success, nv_cxr = pcall(require, 'nvidia')
if not success then
    print("Failed to load CloudXR™ plugin")
    return
end

nv_cxr.initRuntime()
nv_cxr.setRuntimeStringProperty("device-profile", "apple-vision-pro")  -- optional
nv_cxr.startRuntime()
```

**Step 3 — Initialize OpenXR (after CloudXR™ is running):**

```lua
-- For auto-* device profiles, poll nv_cxr.pollEvent() first
-- and compare against nv_cxr.RESULT / nv_cxr.EVENT constants,
-- or retry this step after XR_ERROR_FORM_FACTOR_UNAVAILABLE.
-- See plugins/nvidia/examples/cloudxr/ for the full implementation.
if not HeadsetManager.init() then
    print("Failed to initialize headset")
    return
end

if not CloudXRManager.initOpaqueDataChannel() then
    print("Failed to initialize Opaque Data Channel")
    return
end
```

**Step 4 — Use opaque data channels:**

```lua
function CloudXRManager.update()
    if nv_cxr.getOpaqueDataChannelState() == nv_cxr.OPAQUE_DATA_CHANNEL_STATUS.CONNECTED then
        local data = nv_cxr.receiveOpaqueDataChannel()
        if data then
            print("Received from headset:", data)
            nv_cxr.sendOpaqueDataChannel("Echo: " .. data)
        end
    end
end
```

**Step 5 — Cleanup on shutdown:**

```lua
nv_cxr.destroyRuntime()
```

---

## Advanced Configuration

### Build options

```bash
./build.sh [options]
.\build.bat [options]

Options:
  --lovr-repo <url>                       Custom LOVR repository (also: --lovr-repo=<url>)
  --lovr-branch <branch>                  Use a branch or tag (clears pinned commit)
  --lovr-commit <hash>                    Use a specific commit (clears branch)
  --without-cloudxrjs                     Skip CloudXR.js sample setup (default is enabled)
  Debug|Release|RelWithDebInfo|MinSizeRel Build type (default: Debug)
  --clean                                 Wipe build outputs; keep cached CloudXR archives in build/cloudxr/
```

Anything not listed is forwarded as-is to the `cmake` configure step (e.g. `./build.sh -DLOVR_BUILD_BUNDLE=ON`). This also means typos in option names pass through silently and surface as a `cmake` error rather than a `build.sh` error.

By default the build clones LÖVR and checks out a pinned commit (see `LOVR_COMMIT` near the top of `build.sh` and `build.bat`). Pass `--lovr-branch` or `--lovr-commit` to override; specifying both is not supported (last one wins). `--clean` removes everything in `build/` *except* the cached CloudXR archives so the next build doesn't re-download them. To wipe everything including the archives, delete the build directory: `rm -rf build && ./build.sh` (or `rmdir /s /q build && build.bat`).

**Examples:**

```bash
./build.sh Release                    # Release build with pinned commit
./build.sh --lovr-branch dev          # Build from LÖVR dev branch
./build.sh --without-cloudxrjs        # Skip CloudXR.js setup
./build.sh --clean && ./build.sh      # Clean rebuild (keeps cached archives)
rm -rf build && ./build.sh            # Wipe everything (re-downloads archives)
```

**What gets built:**

- `nvidia.dll` (Windows) or `nvidia.so` (Linux) — the CloudXR™ plugin.
- CloudXR™ runtime libraries and runtime manifest copied to the output directory.
- The example application, ready to run.

### Project layout after a build

The plugin source lives under `plugins/nvidia/`. The build scripts stage everything else (the LÖVR clone, the CloudXR™ SDK, the CloudXR.js sample, build outputs) under `build/` so the repository stays source-only and a clean checkout is just `rm -rf build`.

```text
cloudxr-lovr-plugin-sample/
├── plugins/nvidia/                        # Plugin source (copied/symlinked into build/src/plugins/nvidia/)
│   ├── CMakeLists.txt                     # Reads CLOUDXR_INCLUDE_PATH / CLOUDXR_LIB_PATH
│   ├── src/
│   │   ├── nvidia_cloudxr_*.c             # Core CloudXR™ integration
│   │   └── l_nvidia_cloudxr.c             # Lua bindings
│   └── examples/cloudxr/                  # CloudXR™ Lua example project
└── build/                                 # All generated/downloaded content lives here
    ├── src/                               # LÖVR clone with plugin integrated
    │   └── plugins/nvidia/                # ← plugin copied/symlinked here at build time
    ├── cloudxr/                           # CloudXR™ SDK + CloudXR.js stage area
    │   ├── CloudXR-*-sdk.{tar.gz,zip}     # Cached CloudXR™ Runtime SDK archive
    │   ├── CloudXR-*-sdk/                 # Extracted SDK (headers + runtime libs)
    │   ├── nvidia-cloudxr-*.tgz           # Cached CloudXR.js npm package
    │   ├── cloudxr-js-samples/react/      # CloudXR.js React sample (built by build.sh/build.bat)
    │   └── cloudxr-js-dev-server.log      # Linux dev-server output (auto-webrtc runs)
    ├── bin/                               # Linux LÖVR build output
    ├── Debug/                             # Windows Debug LÖVR build output
    └── Release/                           # Windows Release LÖVR build output
```

> The CloudXR™ SDK is not vendored in this repo. The build scripts extract it to `build/cloudxr/CloudXR-*-sdk/` and pass `CLOUDXR_INCLUDE_PATH` / `CLOUDXR_LIB_PATH` to CMake. Likewise, the CloudXR.js React sample is cloned into `build/cloudxr/cloudxr-js-samples/` from [NVIDIA/cloudxr-js-samples](https://github.com/NVIDIA/cloudxr-js-samples) and the local `nvidia-cloudxr-*.tgz` package is installed into it.

### Use a specific CloudXR Runtime / CloudXR.js version

The build prefers an archive in `build/cloudxr/` whose filename matches `CLOUDXR_RUNTIME_VERSION` / `CLOUDXR_JS_VERSION`. If that exact archive is not present, the build falls back to the first matching `CloudXR-*-Linux*-sdk.tar.gz`, `CloudXR-*-Win64-sdk.zip`, or `nvidia-cloudxr-*.tgz`, and finally downloads the default version from NGC if nothing local matches.

To pin a version, either set `CLOUDXR_RUNTIME_VERSION` / `CLOUDXR_JS_VERSION` in your environment, or edit the defaults near the top of `build.sh` / `build.bat`. To switch SDKs, drop the new archive into `build/cloudxr/`, run `./build.sh --clean` (or `build.bat --clean`), and rebuild — `--clean` keeps cached archives.

The build scripts reuse the previously-extracted SDK in `build/cloudxr/CloudXR-*-sdk/` across builds.

> **Note:** for Apple Vision Pro, use the native CloudXR™ client from the SDK package. For Meta Quest and PICO 4 Ultra, use the CloudXR.js browser client (set up automatically by the build).

For detailed networking requirements (firewall / port info), see the [NVIDIA CloudXR™ SDK Documentation](https://docs.nvidia.com/cloudxr-sdk).

### Device profiles

The runtime supports several CloudXR device profiles. Static profiles connect immediately. `auto-*` profiles wait for a CloudXR client connection before calling `lovr.headset.connect()`. If no profile is set, the sample defaults to `apple-vision-pro`.

```bash
./run.sh                                       # default: apple-vision-pro
./run.sh --device-profile=auto-native
./run.sh --device-profile=auto-webrtc          # also starts CloudXR.js dev server
./run.sh --device-profile=quest3
./run.sh --device-profile=apple-vision-pro

run.bat "--device-profile=auto-webrtc"         # Windows; quote arg, dev server in a new window
```

For `auto-*` profiles, the runtime may report that no OpenXR system is available until a client headset has connected. Apps can either poll CloudXR client-connection events before calling into LÖVR, or retry OpenXR `xrGetSystem` after `XR_ERROR_FORM_FACTOR_UNAVAILABLE`. The sample uses the CloudXR event poll and also tolerates the OpenXR retry path.

> `nv_cxr.pollEvent()` requires CloudXR service API 1.0.7 or newer (CloudXR Runtime 6.0.5+). Compare values returned by `nv_cxr.pollEvent()` with `nv_cxr.RESULT.*` and `nv_cxr.EVENT.*` constants when implementing the polling loop in Lua.

### Headless mode

Pass `--headless` to `run.sh` / `run.bat` to skip the desktop preview window. Use this on a server or cloud GPU that has no display or Vulkan-presentable surface. Frames still render and stream to the CloudXR™ runtime — only the host window is omitted.

```bash
./run.sh --headless
./run.sh --headless --device-profile=auto-native
.\run.bat --headless
```

Internally, `--headless` causes `conf.lua` to leave `t.window = nil` (suppressing LÖVR's window creation) and `main.lua` to install a custom run loop that skips `lovr.graphics.getWindowPass()` and `lovr.graphics.present()`.

### CloudXR.js configuration

CloudXR.js enables streaming this server to web-based headset clients (Meta Quest 2/3/3S, PICO 4 Ultra) over WebRTC. See the [CloudXR.js documentation](https://docs.nvidia.com/cloudxr-sdk/latest/usr_guide/cloudxr_js/index.html) and [client setup guide](https://docs.nvidia.com/cloudxr-sdk/latest/usr_guide/cloudxr_js/client_setup.html) for full details.

**Build behaviour.** By default `./build.sh` / `build.bat` downloads or reuses `build/cloudxr/nvidia-cloudxr-*.tgz`, checks for Node.js v20.19.0+, clones the samples repo to `build/cloudxr/cloudxr-js-samples/`, installs the local CloudXR.js package into the React sample, installs sample dependencies, and runs `npm run build`. Pass `--without-cloudxrjs` to skip all of that. The npm install uses the public registry so stale user-level private registry credentials don't break setup.

**Run behaviour.** When `run.sh`/`run.bat` is invoked with `--device-profile=auto-webrtc`, it starts `npm run dev-server` from `build/cloudxr/cloudxr-js-samples/react` before launching LÖVR.

- On Linux, dev-server output is written to `build/cloudxr/cloudxr-js-dev-server.log` and the server is stopped when `run.sh` exits.
- On Windows, the dev server opens in a separate command window that you must close yourself.
- If port 8080 is already in use, the run script assumes you have your own CloudXR.js server running there and skips starting another one.
- Pass `--without-cloudxrjs` to `run.sh` / `run.bat` to explicitly skip starting the local dev server (useful when you're hosting CloudXR.js on a different host or port and want the run script to stay out of the way).

**Connection modes:**

- **HTTP mode (default)** — simplest local setup. The Quest browser must allow insecure origins for WebXR (see the [Meta Quest configuration](https://docs.nvidia.com/cloudxr-sdk/latest/usr_guide/cloudxr_js/client_setup.html#meta-quest-configuration) section of the CloudXR.js docs).
- **HTTPS mode** — required for production deployments and for headsets whose browser doesn't accept the insecure-origin workaround (e.g. **PICO 4 Ultra**). The dev server started by `run.sh`/`run.bat` is HTTP-only, so for HTTPS you must run your own CloudXR.js server (typically behind a WebSocket SSL proxy like HAProxy or nginx) and tell the run script to skip starting the bundled one:

  ```bash
  ./run.sh --device-profile=auto-webrtc --without-cloudxrjs
  ```

  See the [HTTPS Mode instructions](https://docs.nvidia.com/cloudxr-sdk/latest/usr_guide/cloudxr_js/client_setup.html#https-mode-development-and-production) and [WebSocket Proxy Setup](https://docs.nvidia.com/cloudxr-sdk/latest/usr_guide/cloudxr_js/websocket_proxy_setup.html) for the CloudXR.js server side.
- **HTTPS mode (native TLS)** — alternative to a proxy: the runtime terminates TLS itself when configured with a certificate and key, so clients connect directly via `wss://`. See the [Secure Streaming (TLS)](#secure-streaming-tls) section below.

**Manual CloudXR.js commands.** If you invoke LÖVR directly instead of using `run.sh` / `run.bat`, start the dev server yourself first:

```bash
cd build/cloudxr/cloudxr-js-samples/react
npm run dev-server
```

To re-install the CloudXR.js package and sample dependencies by hand (the build script normally does this for you), run from `build/cloudxr/cloudxr-js-samples/react/`:

```bash
npm --registry https://registry.npmjs.org/ install ../../nvidia-cloudxr-*.tgz
npm --registry https://registry.npmjs.org/ install
npm run build
```

### Provide your own CloudXR™ Runtime SDK archive

The build scripts keep CloudXR™ runtime files under `build/cloudxr/` so the repo stays source-only. If you already have an SDK archive, place it in `build/cloudxr/` before running the build; otherwise the scripts download the default archive with `curl`:

- **Linux**: `build.sh` downloads or reuses `build/cloudxr/CloudXR-<version>-Linux-sdk.tar.gz`.
- **Windows**: `build.bat` downloads or reuses `build\cloudxr\CloudXR-<version>-Win64-sdk.zip`.

`<version>` defaults to `CLOUDXR_RUNTIME_VERSION` (see [Use a specific CloudXR Runtime / CloudXR.js version](#use-a-specific-cloudxr-runtime--cloudxrjs-version)).

The build extracts the SDK in place, passes the include/library paths to CMake (no files are copied into `plugins/nvidia/`), and stages the runtime libraries plus `openxr_cloudxr.json` into the build output during the CMake build.

### Secure Streaming (TLS)

The CloudXR™ Runtime can terminate TLS directly on its signaling endpoint, so CloudXR.js clients can connect over `wss://` without a separate proxy. This is the recommended setup for single-runtime deployments.

#### Generate a self-signed certificate (development)

For local testing, a self-signed certificate is sufficient:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -keyout key.pem -out cert.pem \
    -subj "/CN=<your-server-ip-or-hostname>" \
    -addext "subjectAltName=IP:<your-server-ip>"
```

Replace `<your-server-ip>` with the IP address (or hostname) the headset client will use to reach the server. The `subjectAltName` is required for browsers to accept the cert for that address.

**For production, use a certificate signed by a trusted CA (e.g. Let's Encrypt or an internal CA).**

#### Run with TLS enabled

Pass the PEM files to the run script:

```bash
# Linux
./run.sh --cert /path/to/cert.pem --key /path/to/key.pem

# Windows
run.bat --cert C:\path\to\cert.pem --key C:\path\to\key.pem

# Combine with auto-webrtc device profile for CloudXR.js
./run.sh --cert /path/to/cert.pem --key /path/to/key.pem --device-profile=auto-webrtc
```

Alternatively, export the env vars directly:

```bash
export CLOUDXR_CERT_PATH=/path/to/cert.pem
export CLOUDXR_KEY_PATH=/path/to/key.pem
./run.sh
```

When TLS is enabled you should see this line during startup:

```text
CloudXR native TLS enabled (cert: /path/to/cert.pem)
```

#### Trusting a self-signed certificate in the browser

When using a self-signed certificate, the browser will refuse the `wss://` connection until the cert is trusted for that origin. Have the user navigate to `https://<server-ip>:<port>/` in a separate tab — where `<port>` is the WebRTC signaling port (`49100` by default in `--device-profile=auto-webrtc` mode; `48010` for the native CloudXR client path) — accept the security warning ("Advanced" → "Proceed"), and then return to the CloudXR.js client page. The page you land on after accepting may be blank or show a generic error; only the TLS handshake matters, and the cert is now trusted for that origin.

This step is not needed for certificates signed by a trusted CA.

---

## Troubleshooting

### Check the runtime logs

When the CloudXR™ runtime starts, it logs the log file location, e.g.:

```text
logFile:   /tmp/com.nvidia.cloudxr_MxrYg9/cxr_server.2025-11-18T160550Z.log
```

Open that file to diagnose runtime issues. Most CloudXR™ errors are detailed there.

To send runtime logs to the console instead of a file:

```bash
export NV_CXR_FILE_LOGGING=false
```

### Common issues

| Problem | Diagnosis | Solution |
|---|---|---|
| **"Failed to load plugin"** | Plugin binary not found | Ensure LÖVR was built with plugin support |
| **"CloudXR™ service failed to start"** | Service initialization error | Check the runtime log file. Verify CloudXR™ ports are open in your firewall |
| **"OpenXR runtime not found"** | Runtime JSON not set | Verify `XR_RUNTIME_JSON` points to `openxr_cloudxr.json` |
| **"Failed to start headset"** | LÖVR OpenXR initialization failed | Check the error message that follows. Verify the OpenXR runtime is properly configured |
| **`xrEnumerateInstanceExtensionProperties returned -51` on Windows** | Terminal is elevated; the OpenXR loader ignores `XR_RUNTIME_JSON` when run as Administrator | See [Elevated terminal on Windows (error -51)](#elevated-terminal-on-windows-error--51) |
| **Headset won't connect** | Network or client issue | Ensure both devices are on the same network and the CloudXR™ client is running |
| **Quest browser shows "WebXR not supported"** | Browser flag missing | Configure `unsafely-treat-insecure-origin-as-secure` for `http://<server-ip>:8080` ([instructions](https://docs.nvidia.com/cloudxr-sdk/latest/usr_guide/cloudxr_js/client_setup.html#meta-quest-configuration)) |
| **CloudXR.js page is missing** | React sample not installed or dev server not running | Run `./build.sh` (default behaviour sets it up), or host your own CloudXR.js server. The run scripts warn and continue if the local sample/dev server isn't available. |
| **Port 8080 is already in use** | Existing CloudXR.js server (intentional or orphan) | The run scripts skip the local dev server and continue, assuming the existing server is serving CloudXR.js. To use your own server explicitly, pass `--without-cloudxrjs` to `run.sh`/`run.bat`. To kill an orphan: Linux `fuser -k 8080/tcp`; Windows close the leftover "CloudXR.js dev server" window. |
| **Runtime lock file error** | See [Runtime Lock File Error](#runtime-lock-file-error) | Previous runtime didn't exit cleanly |

### Runtime lock file error

Error message:

```text
ERROR [start] Another instance of the runtime appears to be running (lock file exists at /run/user/361936563/runtime_started)
```

**Cause:** another CloudXR™ runtime is already running, or the previous LÖVR instance crashed before cleaning up.

**Fix:**

1. Stop any other CloudXR™ application.
2. If nothing else is running, delete the lock file:

   ```bash
   rm /run/user/361936563/runtime_started  # Use the path from your error message
   ```

3. Try again.

### Elevated terminal on Windows (error `-51`)

**Symptom:** on Windows, LÖVR fails to start the headset and logs:

```text
xrEnumerateInstanceExtensionProperties returned -51
Failed to initialize headset
```

A CloudXR.js client may show "Connected" while no scene renders, even though the server is streaming frames — so this is **not** a network/NAT issue.

**Cause:** `run.bat` sets `XR_RUNTIME_JSON` to point the OpenXR loader at the CloudXR™ runtime, but the loader deliberately ignores `XR_RUNTIME_JSON` when launched from an elevated (Administrator) context as a security measure. It falls back to the registry's `ActiveRuntime` key — which isn't set — and fails with `-51` (`XR_ERROR_RUNTIME_UNAVAILABLE`). This happens out of the box on AWS Windows Server, where you're logged in as the built-in **Administrator** and every process runs elevated.

**Confirm it:** enable OpenXR loader debug logging and re-run:

```bat
set XR_LOADER_DEBUG=all
run.bat "--device-profile=auto-webrtc"
```

A confirming line appears in the loader output:

```text
!!! WARNING !!! Environment variable XR_RUNTIME_JSON is being ignored due to
running from an elevated context.
```

**Fix:** either launch `run.bat` from a non-elevated terminal, or register the runtime in the registry so the loader finds it regardless of elevation:

```bat
reg add "HKLM\SOFTWARE\Khronos\OpenXR\1" /v ActiveRuntime /t REG_SZ /d "C:\lovr\build\Debug\openxr_cloudxr.json" /f
```

Set the value to the path `run.bat` prints as `XR_RUNTIME_JSON:` on startup (use the `Release` path if you built in Release). After this, the scene streams correctly.

### Linux exit segmentation fault

On Linux you may see this on shutdown:

```text
./run.sh: line ...: 225091 Segmentation fault      "./$(basename "$LOVR_BIN")" "$EXAMPLE_REL_PATH" "$@"
```

This is a known shutdown-time issue in the CloudXR™ Runtime that does not affect runtime functionality. It will be fixed in a future CloudXR™ Runtime release.

### Getting help

- **LÖVR issues**: [LÖVR Documentation](https://lovr.org/docs)
- **CloudXR™ issues**: [NVIDIA CloudXR™ SDK Documentation](https://docs.nvidia.com/cloudxr-sdk)
- **Plugin issues**: see the examples in this repository

---

## License

MIT — see [`LICENSE`](LICENSE).

## Glossary

- **CloudXR™** — NVIDIA's technology for streaming VR/AR applications over the network.
- **LÖVR** — open-source XR framework built on OpenXR using Lua.
- **OpenXR** — cross-platform API standard for VR/AR applications.
- **Runtime** — software layer managing VR/AR hardware via the OpenXR API.
- **Opaque Data Channels** — custom communication channels between app and headset.
- **`XR_RUNTIME_JSON`** — environment variable pointing the OpenXR loader at a runtime.
- **Headset client** — software on the headset that receives and displays the streamed content.
- **Service** — background process managing CloudXR™ streaming.

## Links

- [CloudXR Documentation](https://docs.nvidia.com/cloudxr-sdk/)
- [CloudXR.js Documentation](https://docs.nvidia.com/cloudxr-sdk/latest/usr_guide/cloudxr_js/index.html)
- [CloudXR.js Client Setup Guide](https://docs.nvidia.com/cloudxr-sdk/latest/usr_guide/cloudxr_js/client_setup.html)
- [CloudXR SDK on NGC](https://catalog.ngc.nvidia.com/orgs/nvidia/collections/cloudxr-sdk)
- [CloudXR Runtime Download](https://catalog.ngc.nvidia.com/orgs/nvidia/resources/cloudxr-runtime)
- [CloudXR.js Download](https://catalog.ngc.nvidia.com/orgs/nvidia/resources/cloudxr-js)
- [LÖVR (upstream)](https://github.com/bjornbytes/lovr)
- [LÖVR Docs](https://lovr.org/docs)

## Contributing

This project is not currently accepting external contributions.
