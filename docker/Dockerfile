# syntax=docker/dockerfile:1
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: MIT
#
# Container build for the CloudXR LÖVR plugin sample (linux/amd64). Run
# ./build.sh first to stage the CloudXR SDK in build/cloudxr/, then:
#   docker build -f docker/Dockerfile -t cloudxr-lovr:latest .

ARG CXR_SDK_VERSION=6.2.0
# SDK archive staged in build/cloudxr/ (overridable via build-arg).
ARG CXR_SDK_ARCHIVE=CloudXR-${CXR_SDK_VERSION}-Linux-sdk.tar.gz
ARG LOVR_COMMIT=652d6c80defba554d785c9747e2f5e023fd3f60e

FROM ubuntu:24.04 AS builder
ARG CXR_SDK_ARCHIVE
ARG LOVR_COMMIT

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git ninja-build pkg-config ca-certificates \
        libvulkan-dev libgl1-mesa-dev libegl1-mesa-dev libcurl4-openssl-dev \
        libx11-dev libx11-xcb-dev libxcb1-dev libxext-dev libxrandr-dev \
        libxinerama-dev libxcursor-dev libxi-dev libxrender-dev libxfixes-dev \
        libxxf86vm-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
COPY plugins ./plugins
# SDK root = CLOUDXR_LIB_PATH (libs + plugins/), matching build.sh.
ADD build/cloudxr/${CXR_SDK_ARCHIVE} /sdk/

RUN git init src \
    && git -C src remote add origin https://github.com/bjornbytes/lovr.git \
    && git -C src fetch --depth 1 origin ${LOVR_COMMIT} \
    && git -C src checkout FETCH_HEAD \
    && git -C src submodule update --init --recursive --depth 1 \
    && ln -sfn /work/plugins/nvidia src/plugins/nvidia

RUN cmake -B build -S src -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_ENABLE_EXPORTS=ON \
        -DLOVR_BUILD_WITH_SYMBOLS=ON \
        -DCLOUDXR_INCLUDE_PATH=/sdk/include \
        -DCLOUDXR_LIB_PATH=/sdk \
    && cmake --build build -j"$(nproc)"

# Lightweight runtime image
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=all \
    XR_RUNTIME_JSON=/app/openxr_cloudxr.json \
    NV_CXR_FILE_LOGGING=false \
    NV_CXR_RUNTIME_DIR=/var/run/cloudxr \
    XRT_NO_STDIN=true \
    HOME=/var/run/cloudxr

RUN apt-get update && apt-get install -y --no-install-recommends \
        libatomic1 libbsd0 libegl1 libgl1 libglx0 libvulkan1 libcurl4 \
        libx11-6 libx11-xcb1 libxcb1 libxext6 libxrandr2 libxinerama1 \
        libxcursor1 libxi6 \
        openssl \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/vulkan/icd.d /usr/share/glvnd/egl_vendor.d /var/run/cloudxr \
    && chmod 0755 /var/run/cloudxr
COPY docker/data/10_nvidia.json /usr/share/glvnd/egl_vendor.d/
COPY docker/data/nvidia_icd.json /etc/vulkan/icd.d/
ENV VK_DRIVER_FILES=/etc/vulkan/icd.d/nvidia_icd.json

WORKDIR /app
COPY --from=builder /work/build/bin/ ./
COPY --from=builder /work/plugins/nvidia/examples/cloudxr ./examples/cloudxr

COPY --chmod=0755 docker/entrypoint.sh /entrypoint.sh

# CloudXR streaming ports: 48010/tcp + 49100/tcp signaling, UDP WebRTC media.
# https://docs.nvidia.com/cloudxr-sdk/latest/requirement/network_setup.html#ports-and-firewalls
EXPOSE 48010/tcp 49100/tcp 47998/udp 47999/udp 48000/udp 48002/udp 48005/udp 48008/udp 48012/udp

# --headless: no display in the container. Device profile is left to the
# deployment (app defaults to apple-vision-pro); pass --device-profile=<profile>.
ENTRYPOINT ["/entrypoint.sh"]
CMD ["stdbuf", "-oL", "-eL", "./lovr", "examples/cloudxr", "--headless"]
