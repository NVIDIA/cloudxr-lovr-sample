#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: MIT
set -e

EULA=$(printf '%s' "${ACCEPT_EULA:-}" | tr '[:upper:]' '[:lower:]')
case "$EULA" in
  y|yes|1) ;;
  *)
    echo "Set ACCEPT_EULA=Y to accept the NVIDIA CloudXR EULA:" >&2
    echo "  https://developer.download.nvidia.com/cloudxr/EULA/NVIDIA_CloudXR_GA_License_without_Data_Collection_25Feb2025.pdf" >&2
    exit 1 ;;
esac

# Device profile (native vs WebRTC) via env, so the default CMD (incl. --headless)
# stays intact. e.g. NV_DEVICE_PROFILE=auto-webrtc or auto-native. The sample reads
# --device-profile only from argv, so append it; a later flag wins over any in CMD.
if [ -n "${NV_DEVICE_PROFILE:-}" ]; then
    set -- "$@" "--device-profile=${NV_DEVICE_PROFILE}"
fi

exec "$@"
