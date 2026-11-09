#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""CloudXR cloud settings and loopback-only IPv4 STUN address mapper.

The local responder assumes 1:1, port-preserving cloud NAT. It is not a relay
and cannot discover a translated port or make blocked UDP ports reachable.
"""
import ipaddress
import json
import os
from pathlib import Path
import socket
import struct
import sys
import urllib.request
import zlib

COOKIE = 0x2112A442
DEFAULTS = dict(stun_mode="local", public_ip="", stun_ip="", stun_port=3478, media_port=47998, deployment_mode="direct")


def atomic_json(path, value):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, indent=2) + "\n")
    tmp.replace(path)


def ipv4(value, public=False):
    address = ipaddress.IPv4Address(value)
    if public and not address.is_global:
        raise ValueError("Public media IP must be a globally routable IPv4 address")
    return str(address)


def settings(state):
    path = state / "network.json"
    if not path.exists():
        return DEFAULTS.copy()
    # Existing configurations were created by the cloud-only launcher.
    return DEFAULTS | {"deployment_mode": "cloud"} | json.loads(path.read_text())


def validate(value):
    if value["deployment_mode"] not in {"direct", "cloud"}:
        raise ValueError("Deployment mode must be direct or cloud")
    if value["deployment_mode"] == "direct":
        return value
    if value["stun_mode"] not in {"local", "external"}:
        raise ValueError("STUN mode must be local or external")
    for key in ("stun_port", "media_port"):
        value[key] = int(value[key])
        if not 1 <= value[key] <= 65535:
            raise ValueError(f"Invalid {key}")
    if value["public_ip"]:
        value["public_ip"] = ipv4(value["public_ip"], public=True)
    if value["stun_mode"] == "external":
        value["stun_ip"] = ipv4(value["stun_ip"])
    elif value["stun_port"] == value["media_port"]:
        raise ValueError("Local STUN and media ports must differ")
    return value


def discover_public_ip():
    # EC2's instance address is preferable to a NAT gateway's egress address.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        token = opener.open(urllib.request.Request(
            "http://169.254.169.254/latest/api/token", method="PUT",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"}), timeout=2).read().decode()
        value = opener.open(urllib.request.Request(
            "http://169.254.169.254/latest/meta-data/public-ipv4",
            headers={"X-aws-ec2-metadata-token": token}), timeout=2).read().decode().strip()
        return ipv4(value, public=True)
    except Exception:
        with urllib.request.urlopen("https://api.ipify.org", timeout=8) as response:
            return ipv4(response.read(64).decode().strip(), public=True)


def binding_response(data, peer, public_ip):
    if len(data) < 20:
        return None
    kind, size, cookie = struct.unpack("!HHI", data[:8])
    if kind != 0x0001 or cookie != COOKIE or size % 4 or len(data) != 20 + size:
        return None
    # Validate attribute framing, including padded values.
    pos = 20
    while pos < len(data):
        if pos + 4 > len(data):
            return None
        _, length = struct.unpack("!HH", data[pos:pos + 4])
        pos += 4 + ((length + 3) & ~3)
        if pos > len(data):
            return None
    port = peer[1]
    address = int(ipaddress.IPv4Address(public_ip))
    mapped = struct.pack("!HHBBHI", 0x0001, 8, 0, 1, port, address)
    xor = struct.pack("!HHBBHI", 0x0020, 8, 0, 1, port ^ (COOKIE >> 16), address ^ COOKIE)
    body = mapped + xor
    header = struct.pack("!HHI", 0x0101, len(body) + 8, COOKIE) + data[8:20]
    fingerprint = (zlib.crc32(header + body) & 0xFFFFFFFF) ^ 0x5354554E
    return header + body + struct.pack("!HHI", 0x8028, 4, fingerprint)


def probe(host, port, public_ip=""):
    transaction = os.urandom(12)
    request = struct.pack("!HHI", 1, 0, COOKIE) + transaction
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as stream:
        stream.settimeout(2)
        stream.connect((host, int(port)))
        stream.send(request)
        packet = stream.recv(2048)
    if len(packet) < 20 or packet[8:20] != transaction or struct.unpack("!H", packet[:2])[0] != 0x0101:
        raise ValueError("Invalid STUN Binding response")
    pos = 20
    while pos + 4 <= len(packet):
        kind, length = struct.unpack("!HH", packet[pos:pos + 4])
        value = packet[pos + 4:pos + 4 + length]
        if kind == 0x0020 and length == 8 and value[1] == 1:
            mapped_port, mapped_ip = struct.unpack("!HI", value[2:])
            result = dict(ip=str(ipaddress.IPv4Address(mapped_ip ^ COOKIE)), port=mapped_port ^ (COOKIE >> 16))
            if public_ip and result["ip"] != public_ip:
                raise ValueError("STUN responder reports an unexpected public IP")
            return result
        pos += 4 + ((length + 3) & ~3)
    raise ValueError("STUN response has no IPv4 XOR-MAPPED-ADDRESS")


def main():
    action, *args = sys.argv[1:]
    if action == "save":
        state = Path(args[0])
        value = settings(state)
        if len(args) > 1:
            value.update(zip(DEFAULTS, args[1:]))
        atomic_json(state / "network.json", validate(value))
    elif action == "prepare":
        state = Path(args[0])
        value = validate(settings(state))
        if value["deployment_mode"] == "cloud":
            override = value["public_ip"] or os.environ.get("NV_CXR_ENDPOINT_IP", "")
            value["public_ip"] = ipv4(override, True) if override else discover_public_ip()
            value["stun_ip"] = "127.0.0.1" if value["stun_mode"] == "local" else value["stun_ip"]
            value["enable_ice"] = True
        else:
            # Match the original launcher: endpoint and media-port environment
            # overrides, otherwise ipify and 47998; leave ICE to the profile.
            endpoint = os.environ.get("NV_CXR_ENDPOINT_IP", "")
            if not endpoint:
                with urllib.request.urlopen("https://api.ipify.org", timeout=8) as response:
                    endpoint = response.read(64).decode().strip()
            port = int(os.environ.get("NV_CXR_MEDIA_PORT", "47998"))
            if not endpoint or not 1 <= port <= 65535:
                raise ValueError("Invalid original-mode endpoint or media port")
            value.update(public_ip=endpoint, media_port=port, stun_ip="", stun_port=0, enable_ice=None)
        atomic_json(state / "current.network.json", value)
        print(*(value[key] for key in ("public_ip", "stun_ip", "stun_port", "media_port", "stun_mode", "deployment_mode")), sep="\n")
    elif action == "patch":
        path = Path(args[0]) / "plugins/nvidia/examples/cloudxr/cloudxr_manager.lua"
        source = path.read_text()
        if "-- Brev cloud network configuration" not in source:
            anchor = "    -- Start the CloudXR service - this begins the streaming process"
            if source.count(anchor) != 1:
                raise ValueError("Sample startup changed; cannot safely insert cloud configuration")
            block = '''    -- Brev cloud network configuration (applied before service startup).
    local cloudConfig = os.getenv("CLOUDXR_CLOUD_CONFIG_LUA")
    if cloudConfig and not dofile(cloudConfig)(nv_cxr) then
        nv_cxr.destroyRuntime()
        return false
    end

'''
            path.write_text(source.replace(anchor, block + anchor))
    elif action == "serve":
        public_ip, port = ipv4(args[0], True), int(args[1])
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as stream:
            stream.bind(("127.0.0.1", port))
            print(f"Local STUN 127.0.0.1:{port} -> {public_ip}, preserving each source port (requires 1:1 NAT)", flush=True)
            while True:
                packet, peer = stream.recvfrom(4096)
                response = binding_response(packet, peer, public_ip)
                if response:
                    stream.sendto(response, peer)
                    print(f"Binding {peer[0]}:{peer[1]} -> {public_ip}:{peer[1]}", flush=True)
    elif action == "probe":
        print(json.dumps(probe(*args)))
    else:
        raise ValueError("Unknown cloud network command")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        raise SystemExit(f"Cloud networking: {exc}")
