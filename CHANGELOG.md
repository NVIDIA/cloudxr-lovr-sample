# Changelog

## 1.2.0

### Added

- Docker support: containerize the CloudXR LÖVR sample with a `docker/Dockerfile`, entrypoint, and NVIDIA GPU/Vulkan ICD configuration for server/cloud deployments.
- Select the CloudXR device profile in the container via the `NV_DEVICE_PROFILE` environment variable.
- Headless mode for server/cloud GPU deployments (no local display/HMD required).
- Native TLS support for the CloudXR runtime (`wss://`) via `--cert`/`--key` flags on `run.sh` / `run.bat`, or the `CLOUDXR_CERT_PATH` / `CLOUDXR_KEY_PATH` environment variables.

### Changed

- Repinned the LÖVR commit to a newer version.
- Build scripts fail fast with clear Node.js installation guidance when Node is missing during CloudXR.js setup.

## 1.1.1

### Fixed

- `run.bat`: escaped the parentheses in the CloudXR.js dev-server warning so `cmd.exe` no longer mis-parses the `echo` inside the `if ()` block. This blocked `run.bat` from running on Windows Server.

### Changed

- README and `run.bat` quick reference: quote the `--device-profile` argument in the Windows examples (`run.bat "--device-profile=auto-webrtc"`) so `cmd.exe` doesn't split on the `=`.

### Documentation

- Documented the elevated/Administrator OpenXR failure on Windows: when launched from an elevated terminal (the default on AWS Windows Server's built-in Administrator), the loader ignores `XR_RUNTIME_JSON` and fails with `-51` (`XR_ERROR_RUNTIME_UNAVAILABLE`). Added the registry `ActiveRuntime` workaround and the `XR_LOADER_DEBUG=all` diagnostic.

## 1.1.0

### Added

- Meta Quest 2/3/3S and PICO 4 Ultra support via CloudXR.js over WebRTC.
- Support for CloudXR `auto-*` device profiles (`auto-native`, `auto-webrtc`) from Lua.
- Haptics in the example app via `lovr.headset.vibrate()`.
- Build scripts auto-stage the CloudXR Runtime SDK and CloudXR.js package from local archives or NGC.
- `--clean` flag on the build scripts to wipe build outputs while preserving cached CloudXR archives.

### Changed

- CloudXR.js sample is now set up by default. Pass `--without-cloudxrjs` to `build.sh` / `build.bat` to opt out, or to `run.sh` / `run.bat` to skip starting the local dev server.
- README reorganized into a novice-first Quick Start with an Advanced Configuration section.
- Repinned LÖVR commit to a version that builds at top of tree.
- Windows build copies the plugin folder into `build/src/` instead of using a directory junction.

## 1.0.1

- Pin LOVR commit to a specific version
- Linux: Remove unnecessary broken chrpath post-build step that corrupts CloudXR SDK RPATH
- Update documentation for CloudXR.js
