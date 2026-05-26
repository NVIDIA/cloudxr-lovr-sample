# Changelog

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
