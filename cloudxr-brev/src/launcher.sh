#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$SCRIPT_DIR/launcher.sh"
STATE_DIR="${CLOUDXR_STATE:-$HOME/.cache/cloudxr-experiences}"
XDG_RUNTIME_DIR="${CLOUDXR_XDG_RUNTIME_DIR:-$STATE_DIR/xdg-runtime}"
SOURCE_REPO="$STATE_DIR/source"
SOURCE_ROOT_FILE="$STATE_DIR/source.root"
SOURCE_COMMIT_FILE="$STATE_DIR/source.commit"
FLAVOR_ROOT="$STATE_DIR/flavors"
PID_FILE="$STATE_DIR/deploy.pid"
MODE_FILE="$STATE_DIR/current.mode"
RUNTIME_FILE="$STATE_DIR/current.runtime"
JS_FILE="$STATE_DIR/current.js"
FRAMEWORK_FILE="$STATE_DIR/current.framework"
APPLE_PROFILE_FILE="$STATE_DIR/apple.profile"
DEVICE_PROFILE_FILE="$STATE_DIR/current.device-profile"
ENDPOINT_FILE="$STATE_DIR/current.endpoint"
FLAVOR_FILE="$STATE_DIR/current.flavor"
PHASE_FILE="$STATE_DIR/current.phase"
EXIT_FILE="$STATE_DIR/current.exit"
APP_LOG="$STATE_DIR/server.log"
PROXY_LOG="$STATE_DIR/proxy.log"
UI_PID_FILE="$STATE_DIR/ui.pid"
UI_LOG="$STATE_DIR/ui.log"
REBOOT_MARKER="$STATE_DIR/gpu-reboot"
NETWORK_HELPER="$SCRIPT_DIR/cloud-network.py"
STUN_LOG="$STATE_DIR/stun.log"
STUN_PID_FILE="$STATE_DIR/stun.pid"
UI_PORT=8080
UI_BACKEND_PORT=8081
NATIVE_PORT=48010
MIN_DRIVER=580
RUN_USER="${SUDO_USER:-${USER:-$(id -un)}}"
REBOOT_SCHEDULED=0
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH" XDG_RUNTIME_DIR
die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "CloudXR Experiences: $*" >&2; }
first_line() { [[ -s "$1" ]] && head -n 1 "$1"; }
pid_alive() {
  local pid
  pid="$(first_line "$1" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] && { kill -0 "$pid" 2>/dev/null || [[ -d "/proc/$pid" ]]; }
}
valid_port() { [[ "$2" =~ ^[0-9]+$ ]] && (( 1 <= $2 && $2 <= 65535 )) || die "$1 is not a valid port: $2"; }
valid_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; }
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }
driver_major() {
  local v
  v="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
  [[ -n "$v" ]] || v="$(grep -oE '[0-9]+\.[0-9]+' /proc/driver/nvidia/version 2>/dev/null | head -n1 || true)"
  printf '%s\n' "${v%%.*}"
}
is_sample() { [[ -x "$1/build.sh" && -x "$1/run.sh" && -f "$1/plugins/nvidia/examples/cloudxr/main.lua" ]]; }
validate_flavor() {
  local mode="$1" runtime="$2" js="$3" framework="$4"
  [[ "$mode" == apple || "$mode" == webxr ]] || die "mode must be apple or webxr"
  valid_version "$runtime" || die "invalid CloudXR Runtime version: $runtime"
  valid_version "$js" || die "invalid CloudXR.js version: $js"
  valid_version "$framework" || die "invalid CloudXR Framework version: $framework"
  version_ge "$runtime" 6.0.2 || die "CloudXR Runtime 6.0.2+ is required"
  version_ge "$framework" 6.0.2 || die "CloudXR Framework 6.0.2+ is required"
  if [[ "$mode" == webxr ]]; then
    [[ "${runtime%%.*}" == "${js%%.*}" ]] || die "CloudXR Runtime and CloudXR.js must use the same major version"
    version_ge "$runtime" 6.0.5 || die "WebXR auto-webrtc requires CloudXR Runtime 6.0.5+"
    version_ge "$js" 6.1.0 || die "CloudXR.js 6.1.0+ is required"
  else
    [[ "${runtime%%.*}" == "${framework%%.*}" ]] || die "CloudXR Runtime and CloudXR Framework must use the same major version"
  fi
}
source_root() {
  if [[ -n "${CLOUDXR_LOVR_ROOT:-}" ]]; then printf '%s\n' "$CLOUDXR_LOVR_ROOT"; else first_line "$SOURCE_ROOT_FILE" 2>/dev/null || true; fi
}
ensure_source() {
  mkdir -p "$STATE_DIR" "$FLAVOR_ROOT"
  if [[ -n "${CLOUDXR_LOVR_ROOT:-}" ]]; then
    is_sample "$CLOUDXR_LOVR_ROOT" || die "$CLOUDXR_LOVR_ROOT is not a cloudxr-lovr-sample checkout"
    printf '%s\n' "$(cd "$CLOUDXR_LOVR_ROOT" && pwd -P)" > "$SOURCE_ROOT_FILE"
    git -C "$CLOUDXR_LOVR_ROOT" rev-parse HEAD > "$SOURCE_COMMIT_FILE" 2>/dev/null || printf '%s\n' local > "$SOURCE_COMMIT_FILE"
    return
  fi
  local repository="${CLOUDXR_LOVR_REPOSITORY_URL:-https://github.com/NVIDIA/cloudxr-lovr-sample.git}" commit
  if [[ ! -e "$SOURCE_REPO/.git" ]]; then
    mkdir -p "$SOURCE_REPO"; git -C "$SOURCE_REPO" init -q; git -C "$SOURCE_REPO" remote add origin "$repository"
  fi
  git -C "$SOURCE_REPO" rev-parse --git-dir >/dev/null 2>&1 || die "$SOURCE_REPO is not a Git checkout"
  git -C "$SOURCE_REPO" remote set-url origin "$repository"
  note "fetching the latest cloudxr-lovr-sample main"
  git -C "$SOURCE_REPO" fetch --quiet --depth 1 origin main
  commit="$(git -C "$SOURCE_REPO" rev-parse FETCH_HEAD)"
  printf '%s\n' "$commit" > "$SOURCE_COMMIT_FILE"
  : > "$SOURCE_ROOT_FILE"
}
ensure_node() {
  export NVM_DIR="$HOME/.nvm"
  [[ -s "$NVM_DIR/nvm.sh" ]] || git clone -q -b v0.40.6 --depth 1 https://github.com/nvm-sh/nvm "$NVM_DIR"
  . "$NVM_DIR/nvm.sh"
  nvm use 24 >/dev/null 2>&1 || nvm install 24
}
install_boot_service() {
  sudo -n tee /etc/systemd/system/cloudxr-experiences.service >/dev/null <<EOF
[Unit]
After=network-online.target
[Service]
Type=oneshot
User=$RUN_USER
Environment=HOME=$HOME
ExecStart=$SELF setup
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  sudo -n systemctl daemon-reload
  sudo -n systemctl enable cloudxr-experiences.service >/dev/null
}
upgrade_gpu_driver() {
  [[ "${CLOUDXR_UPGRADE_GPU_DRIVER:-1}" =~ ^(1|true|yes|on)$ ]] || return
  grep -q '^ID=ubuntu' /etc/os-release || die "automatic GPU driver upgrades require Ubuntu"
  local v p b old
  v="$(driver_major)"
  if [[ "$v" =~ ^[0-9]+$ ]] && (( v >= MIN_DRIVER )); then rm -f "$REBOOT_MARKER"; return; fi
  [[ ! -e "$REBOOT_MARKER" ]] || die "GPU driver failed after reboot"
  note "upgrading the NVIDIA driver"
  sudo -n apt-get update -qq
  sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-drivers-common "linux-headers-$(uname -r)"
  p="$(ubuntu-drivers devices 2>/dev/null | awk '/recommended/ {print $3; exit}')"
  [[ "$p" == nvidia-driver-* ]] || die "no compatible NVIDIA driver package is available"
  b="${p#nvidia-driver-}"; b="${b%-open}"
  [[ "${b%%-*}" =~ ^[0-9]+$ ]] && (( ${b%%-*} >= MIN_DRIVER )) || die "NVIDIA driver $MIN_DRIVER+ is unavailable"
  old=""; [[ "$v" =~ ^[0-9]+$ ]] && old="$(dpkg-query -W -f='${binary:Package}\n' "*-$v*" 2>/dev/null | grep -E 'nvidia|cuda' || true)"
  [[ -z "$old" ]] || sudo -n env DEBIAN_FRONTEND=noninteractive apt-get remove -y --allow-change-held-packages --autoremove --purge $old
  sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-change-held-packages "$p" "libnvidia-gl-$b" "libnvidia-encode-$b"
  : > "$REBOOT_MARKER"; install_boot_service
  note "GPU driver updated; reboot scheduled; setup will resume at boot"
  sudo -n shutdown -r +1; REBOOT_SCHEDULED=1
}
ensure_build_dependencies() {
  if [[ "${CLOUDXR_SKIP_PACKAGES:-0}" =~ ^(1|true|yes|on)$ ]]; then return; fi
  grep -q '^ID=ubuntu' /etc/os-release || die "automatic dependency installation requires Ubuntu"
  local p v
  note "installing LÖVR, Vulkan, and NVENC dependencies"
  sudo -n apt-get update -qq
  p="$(dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' 'nvidia-driver-*' 2>/dev/null | awk '$1=="ii"{print $2;exit}' || true)"
  if [[ "$p" == nvidia-driver-* ]]; then p="${p#nvidia-driver-}"; p="${p%-open}"; else p="$(driver_major)"; fi
  [[ "$p" =~ ^[0-9]+(-server)?$ ]] || die "loaded NVIDIA driver branch is unavailable"
  v="$(dpkg-query -W -f='${Version}' "libnvidia-compute-$p" 2>/dev/null || true)"; [[ -z "$v" ]] || v="=$v"
  sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --allow-change-held-packages \
    build-essential cmake git curl ca-certificates xorg-dev libcurl4-openssl-dev \
    libxcb-glx0-dev libx11-xcb-dev libvulkan1 vulkan-tools python3-minimal haproxy \
    "nvidia-utils-$p$v" "libnvidia-gl-$p$v" "libnvidia-encode-$p$v"
}
flavor_path() {
  printf '%s/%s-webxr-rt-%s-js-%s\n' "$FLAVOR_ROOT" "${4:0:12}" "$2" "$3"
}
ensure_runtime_archive() {
  local root="$1" version="$2" dir file candidate part
  dir="$root/build/cloudxr"; mkdir -p "$dir"
  for candidate in "$dir"/CloudXR-"$version"-Linux*-sdk "$dir"/CloudXR-"$version"-Linux*-sdk.tar.gz; do [[ -e "$candidate" ]] && return; done
  file="$(curl -fsSL --max-time 20 "https://api.ngc.nvidia.com/v2/resources/nvidia/cloudxr-runtime/versions/$version/files" | python3 -c 'import json,sys;v=sys.argv[1];a=[x.get("path","") for x in json.load(sys.stdin).get("recipeFiles",[])];a=[x for x in a if x.startswith(f"CloudXR-{v}-Linux") and x.endswith("-sdk.tar.gz") and "/" not in x and not any(y in x.lower() for y in ("arm64","aarch64"))];print(a[0] if len(a)==1 else "")' "$version")"
  [[ "$file" == "CloudXR-$version-Linux"*"-sdk.tar.gz" && "$file" != */* ]] || die "NGC has no unambiguous Linux x86 Runtime archive for $version"
  part="$dir/$file.part"; note "downloading CloudXR Runtime $version ($file)"
  curl -fsSL --retry 3 "https://api.ngc.nvidia.com/v2/resources/org/nvidia/cloudxr-runtime/$version/files?redirect=true&path=$file" -o "$part"
  mv "$part" "$dir/$file"
}
ensure_js_sample() {
  local dir package
  dir="$1/build/cloudxr/cloudxr-js-samples"; package="$dir/react/package.json"
  [[ -f "$package" ]] || git clone -q --depth 1 https://github.com/NVIDIA/cloudxr-js-samples.git "$dir"
  sed -E 's/("(react|react-dom)"[[:space:]]*:[[:space:]]*)"\^([^"]+)"/\1"\3"/' "$package" > "$package.tmp"
  mv "$package.tmp" "$package"
}
ensure_flavor() {
  local runtime="$2" js="$3" commit root marker
  commit="$(first_line "$SOURCE_COMMIT_FILE")"
  if [[ -n "${CLOUDXR_LOVR_ROOT:-}" ]]; then
    root="$(source_root)"
  else
    root="$(flavor_path "$mode" "$runtime" "$js" "$commit")"
    if [[ ! -e "$root/.git" ]]; then
      [[ ! -e "$root" ]] || die "$root exists but is not a Git worktree"
      git -C "$SOURCE_REPO" worktree add --quiet --detach "$root" "$commit"
    fi
  fi
  marker="$root/.brev-ready"
  if [[ -s "$marker" && -x "$root/build/bin/lovr" && -s "$root/build/bin/openxr_cloudxr.json" && -s "$root/build/cloudxr/cloudxr-js-samples/react/build/index.html" ]] && grep -qxF "$commit webxr $runtime $js" "$marker"; then
    note "reusing cached flavor $(basename "$root")"
    printf '%s\n' "$root" > "$FLAVOR_FILE"
    return
  fi
  ensure_node
  ensure_runtime_archive "$root" "$runtime"
  ensure_js_sample "$root"
  note "building LÖVR main $commit with Runtime $runtime and CloudXR.js $js"
  (
    cd "$root"
    export CLOUDXR_RUNTIME_VERSION="$runtime" CLOUDXR_JS_VERSION="$js"
    ./build.sh Release -DLOVR_PLUGINS=plugins/nvidia
  )
  [[ -x "$root/build/bin/lovr" && -s "$root/build/bin/openxr_cloudxr.json" ]] || die "LÖVR build output is incomplete"
  [[ -s "$root/build/cloudxr/cloudxr-js-samples/react/build/index.html" ]] || die "CloudXR.js client build is incomplete"
  printf '%s\n' "$commit webxr $runtime $js" > "$marker"
  printf '%s\n' "$root" > "$FLAVOR_FILE"
}
catalog() {
  mkdir -p "$STATE_DIR"
  python3 - "$STATE_DIR" "$@" <<'PY'
import json, os, platform, re, subprocess, sys
from pathlib import Path
state = Path(sys.argv[1])
def run(argv, timeout=8):
    try: return subprocess.check_output(argv, text=True, stderr=subprocess.DEVNULL, timeout=timeout).strip()
    except (OSError, subprocess.SubprocessError): return ""
def version_key(value):
    match = re.fullmatch(r"\d+\.\d+\.\d+([.-][\w.-]+)?", value)
    return tuple(map(int, re.findall(r"\d+", value)[:3])) if match else ()
def version_catalog():
    floors = {"runtime": (6, 0, 2), "js": (6, 1, 0), "framework": (6, 0, 2)}
    cache_file = state / "versions.json"
    try: cached = json.loads(cache_file.read_text())
    except (OSError, ValueError): cached = {}
    cached = cached.get("versions", cached)
    if cached and "--refresh" not in sys.argv: return cached
    versions = {key: list(cached.get(key, [])) for key in floors}
    api = "https://api.ngc.nvidia.com/v2/resources/nvidia"
    raw = {key: run(["curl", "-fsSL", "--max-time", "6", f"{api}/cloudxr-{resource}/versions?page-size=100"]) for key, resource in (("runtime", "runtime"), ("js", "js"))}
    raw["framework"] = run(["git", "ls-remote", "--tags", "--refs", "https://github.com/NVIDIA/cloudxr-framework.git"])
    live = {}
    for key in ("runtime", "js"):
        try: live[key] = [item["versionId"] for item in json.loads(raw[key])["recipeVersions"] if item.get("status") == "UPLOAD_COMPLETE"]
        except Exception: live[key] = []
    live["framework"] = [line.rsplit("/", 1)[-1] for line in raw["framework"].splitlines()]
    for key, values in live.items():
        found = {v for v in values if version_key(v) >= floors[key]}
        if found: versions[key] = sorted(found, key=version_key, reverse=True)
    cache_file.write_text(json.dumps(versions, separators=(",", ":")))
    return versions
versions = version_catalog()
raw = run(["nvidia-smi", "--query-gpu=index,name,memory.total,driver_version", "--format=csv,noheader,nounits"])
enc_raw = run(["nvidia-smi", "--query-gpu=index,encoder.stats.sessionCount", "--format=csv,noheader,nounits"])
enc = {}
for line in enc_raw.splitlines():
    parts = [v.strip() for v in line.split(",", 1)]
    if len(parts) == 2: enc[parts[0]] = parts[1].lower() not in {"", "n/a", "[n/a]", "not supported", "[not supported]"}
gpus, driver = [], ""
for line in raw.splitlines():
    parts = [v.strip() for v in line.split(",")]
    if len(parts) != 4: continue
    try: gpus.append({"index": int(parts[0]), "name": parts[1], "memory_mib": int(float(parts[2])), "nvenc": bool(enc.get(parts[0]))})
    except ValueError: continue
    driver = driver or parts[3]
try: os_release = platform.freedesktop_os_release()
except OSError: os_release = {}
probe_path = os.environ.get("CLOUDXR_PROBE_FIXTURE")
if probe_path:
    probe = json.loads(Path(probe_path).read_text()); gpus = probe.get("gpus", gpus); driver = probe.get("driver_version", driver)
    os_release = {"ID": probe.get("os_id", "ubuntu"), "VERSION_ID": probe.get("os_version", "24.04")}
    machine = probe.get("machine", "x86_64"); system = probe.get("system", "Linux")
else: machine, system = platform.machine(), platform.system()
blockers = []
if system != "Linux": blockers.append("Linux is required")
if machine not in {"x86_64", "amd64"}: blockers.append("64-bit x86 is required")
if os_release.get("ID") != "ubuntu" or tuple(int(v) for v in re.findall(r"\d+", os_release.get("VERSION_ID", "0"))[:2]) < (22, 4): blockers.append("Ubuntu 22.04+ is required")
driver_parts = tuple(int(v) for v in re.findall(r"\d+", driver)[:1])
if driver_parts < (580,): blockers.append("NVIDIA driver 580+ is required")
if not any(gpu.get("nvenc") for gpu in gpus): blockers.append("an NVENC-capable NVIDIA graphics GPU is required")
result = {"driver_version": driver, "gpus": gpus, "blockers": blockers, "runnable": not blockers, "versions": versions}
args = sys.argv[2:]
if args and args[0] == "--latest":
    if not all(versions.values()): raise SystemExit("version catalog unavailable")
    print(*(versions[key][0] for key in ("runtime", "js", "framework"))); raise SystemExit()
if args and args[0] == "--check":
    if blockers: print("; ".join(blockers), file=sys.stderr); raise SystemExit(1)
    raise SystemExit()
print(json.dumps(result, separators=(",", ":")))
PY
}
acquire_lock() { mkdir "$STATE_DIR/action.lock" 2>/dev/null || die "another launcher action is in progress"; }
release_lock() { rmdir "$STATE_DIR/action.lock" 2>/dev/null || true; }
runtime_lock_file() { printf '%s/runtime_started\n' "$XDG_RUNTIME_DIR"; }
stop_locked() {
  local pid attempt
  if pid_alive "$PID_FILE"; then
    pid="$(first_line "$PID_FILE")"; note "stopping active flavor (PID $pid)"
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    # The deployment shell can exit before its rendering child. Wait for the
    # process group, then clean up surviving children even if the leader exited.
    for ((attempt=0; attempt<30; attempt++)); do
      ps -eo pgid=,stat= | awk -v id="$pid" '$1==id && $2 !~ /^Z/{found=1} END{exit !found}' || break
      sleep 1
    done
    kill -KILL -- "-$pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$PID_FILE" "$STUN_PID_FILE" "$(runtime_lock_file)"
  printf '%s\n' stopped > "$PHASE_FILE"
}
stop_flavor() {
  mkdir -p "$STATE_DIR"; acquire_lock; trap release_lock EXIT
  stop_locked; note "flavor stopped"
  release_lock; trap - EXIT
}
start_flavor() {
  local mode="${1:?mode}" runtime="${2:?runtime}" js="${3:?js}" framework="${4:?framework}" pid
  local apple_profile="${11:-$(first_line "$APPLE_PROFILE_FILE" 2>/dev/null || true)}"
  apple_profile="${apple_profile:-apple-vision-pro}"
  [[ "$apple_profile" == apple-vision-pro || "$apple_profile" == ipad-pro ]] || die "Apple profile must be apple-vision-pro or ipad-pro"
  [[ "$mode" == webrtc ]] && mode=webxr
  mkdir -p "$STATE_DIR" "$FLAVOR_ROOT"
  validate_flavor "$mode" "$runtime" "$js" "$framework"
  catalog --check >/dev/null || die "hardware validation failed"
  acquire_lock; trap release_lock EXIT
  if (( $# > 4 )); then
    python3 "$NETWORK_HELPER" save "$STATE_DIR" "${5:?stun mode}" "${6-}" "${7-}" "${8:-3478}" "${9:-47998}" "${10:-cloud}"
  else
    python3 "$NETWORK_HELPER" save "$STATE_DIR"
  fi
  stop_locked
  printf '%s\n' "$apple_profile" > "$APPLE_PROFILE_FILE"
  if [[ "$mode" == apple ]]; then printf '%s\n' "$apple_profile" > "$DEVICE_PROFILE_FILE"; else printf '%s\n' auto-webrtc > "$DEVICE_PROFILE_FILE"; fi
  printf '%s\n' "$mode" > "$MODE_FILE"; printf '%s\n' "$runtime" > "$RUNTIME_FILE"
  printf '%s\n' "$js" > "$JS_FILE"; printf '%s\n' "$framework" > "$FRAMEWORK_FILE"
  printf '%s\n' queued > "$PHASE_FILE"; : > "$APP_LOG"; : > "$PROXY_LOG"; rm -f "$EXIT_FILE" "$FLAVOR_FILE"
  nohup setsid "$SELF" _deploy "$mode" "$runtime" "$js" "$framework" "$apple_profile" >> "$APP_LOG" 2>&1 </dev/null &
  pid=$!; printf '%s\n' "$pid" > "$PID_FILE"; sleep 1
  pid_alive "$PID_FILE" || { tail -n 80 "$APP_LOG" >&2; die "flavor failed to start"; }
  note "building or starting $mode with Runtime $runtime (PID $pid)"
  release_lock; trap - EXIT
}
run_flavor() {
  local mode="$1" root="$2" apple_profile="${3:-apple-vision-pro}" rc=0 icd="$STATE_DIR/nvidia_icd.json"
  sed 's/libGLX_nvidia/libEGL_nvidia/' "$root/docker/data/nvidia_icd.json" > "$icd"
  local settings line stun_pid=""
  local -a network
  settings="$(python3 "$NETWORK_HELPER" prepare "$STATE_DIR")" || die "invalid cloud network configuration"
  network=(); while IFS= read -r line; do network+=("$line"); done <<< "$settings"
  export NV_CXR_ENDPOINT_IP="${network[0]}" NV_CXR_MEDIA_PORT="${network[3]}"
  printf '%s\n' "$NV_CXR_ENDPOINT_IP" > "$ENDPOINT_FILE"
  if [[ "${network[5]}" == cloud ]]; then
    export CLOUDXR_STUN_IP="${network[1]}" CLOUDXR_STUN_PORT="${network[2]}"
    export NV_CXR_STREAMSDK_ENABLE_ICE=true NV_CXR_STUN_SERVER_IP="$CLOUDXR_STUN_IP" NV_CXR_STUN_SERVER_PORT="$CLOUDXR_STUN_PORT"
    export CLOUDXR_CLOUD_CONFIG_LUA="$SCRIPT_DIR/cloud-runtime.lua"
    python3 "$NETWORK_HELPER" patch "$root" || die "cannot configure sample startup"
    if [[ "${network[4]}" == local ]]; then
      python3 -u "$NETWORK_HELPER" serve "$NV_CXR_ENDPOINT_IP" "$CLOUDXR_STUN_PORT" >> "$STUN_LOG" 2>&1 &
      stun_pid=$!; printf '%s\n' "$stun_pid" > "$STUN_PID_FILE"
      sleep 0.2
      kill -0 "$stun_pid" 2>/dev/null || die "local STUN failed; see stun.log"
      python3 "$NETWORK_HELPER" probe "$CLOUDXR_STUN_IP" "$CLOUDXR_STUN_PORT" "$NV_CXR_ENDPOINT_IP" || die "local STUN health check failed"
      trap "kill '$stun_pid' 2>/dev/null || true; rm -f '$STUN_PID_FILE'" EXIT
    fi
    note "cloud media: $NV_CXR_ENDPOINT_IP:$NV_CXR_MEDIA_PORT/udp; ICE enabled; STUN $CLOUDXR_STUN_IP:$CLOUDXR_STUN_PORT (${network[4]})"
  else
    unset CLOUDXR_CLOUD_CONFIG_LUA CLOUDXR_STUN_IP CLOUDXR_STUN_PORT
    unset NV_CXR_STREAMSDK_ENABLE_ICE NV_CXR_STUN_SERVER_IP NV_CXR_STUN_SERVER_PORT
    unset NV_CXR_STUN_USERNAME NV_CXR_STUN_CREDENTIAL
    note "original deployment: $NV_CXR_ENDPOINT_IP:$NV_CXR_MEDIA_PORT/udp; runtime profile defaults; no configured STUN"
  fi
  export NV_CXR_FILE_LOGGING=false VK_ICD_FILENAMES="$icd"
  mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
  vulkaninfo --summary || die "NVIDIA Vulkan unavailable"
  printf '%s\n' starting > "$PHASE_FILE"
  cd "$root"; set +e
  if [[ "$mode" == webxr ]]; then
    stdbuf -oL -eL ./run.sh --headless --without-cloudxrjs --device-profile=auto-webrtc
  else
    stdbuf -oL -eL ./run.sh --headless --device-profile="$apple_profile"
  fi
  rc=$?; set -e
  return "$rc"
}
deploy_flavor() {
  local mode="$1" runtime="$2" js="$3" framework="$4" apple_profile="${5:-apple-vision-pro}" root rc=0
  printf '%s\n' syncing > "$PHASE_FILE"
  set +e
  (
    set -Eeuo pipefail
    ensure_source
    printf '%s\n' building > "$PHASE_FILE"
    ensure_flavor "$mode" "$runtime" "$js"
    root="$(first_line "$FLAVOR_FILE")"
    run_flavor "$mode" "$root" "$apple_profile"
  )
  rc=$?; set -e
  printf '%s\n' "$rc" > "$EXIT_FILE"
  (( rc == 0 )) && printf '%s\n' stopped > "$PHASE_FILE" || printf '%s\n' failed > "$PHASE_FILE"
  exit "$rc"
}
serve_http() {
  exec python3 - "$SELF" "$SCRIPT_DIR/ui.html" "$STATE_DIR" "$UI_BACKEND_PORT" "$NATIVE_PORT" <<'PY'
import json, mimetypes, os, subprocess, sys, importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse
app, page_path, state = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
port, native_port = map(int, sys.argv[4:6])
page = page_path.read_bytes()
spec = importlib.util.spec_from_file_location("cloud_network", page_path.with_name("cloud-network.py"))
network_module = importlib.util.module_from_spec(spec); spec.loader.exec_module(network_module)
def network_status():
    try: current = json.loads((state / "current.network.json").read_text())
    except (OSError, ValueError): current = {}
    return {"settings": network_module.settings(state), "current": current,
            "local_stun_running": alive(first("stun.pid"))}

def first(name):
    try: return (state / name).read_text().splitlines()[0].strip()
    except (OSError, IndexError): return ""
def alive(raw):
    try: os.kill(int(raw), 0); return True
    except PermissionError: return Path(f"/proc/{raw}").exists()
    except (ValueError, OSError): return False
def tail(path, amount=100000):
    try:
        with path.open("rb") as stream:
            stream.seek(0, os.SEEK_END); size = stream.tell(); stream.seek(max(0, size - amount)); return stream.read().decode(errors="replace")
    except OSError: return ""
def contains(path, needle):
    try:
        with path.open("rb") as stream: return any(needle in line for line in stream)
    except OSError: return False
def process_status():
    pid, phase, path = first("deploy.pid"), first("current.phase") or "stopped", state / "server.log"
    log, marker = tail(path), b"Runtime is now running and accepting connections"
    running = alive(pid)
    if "service->start() failed" in log: phase = "failed"
    elif running and (phase == "ready" or marker.decode() in log or phase == "starting" and contains(path, marker)):
        if phase != "ready":
            try: (state / "current.phase").write_text("ready\n")
            except OSError: pass
        phase = "ready"
    elif running and phase not in {"syncing", "building", "starting", "queued", "ready"}: phase = "starting"
    elif not running and first("current.exit") not in {"", "0"}: phase = "failed"
    elif not running and phase not in {"failed", "stopped"}: phase = "stopped"
    return {"pid": int(pid) if pid.isdigit() else None, "state": phase, "mode": first("current.mode"), "runtime": first("current.runtime"), "js": first("current.js"), "framework": first("current.framework"), "endpoint": first("current.endpoint"), "apple_profile": first("apple.profile") or "apple-vision-pro", "device_profile": first("current.device-profile") or ("auto-webrtc" if first("current.mode") == "webxr" else "apple-vision-pro")}
def inventory():
    result = subprocess.run([app, "catalog"], text=True, capture_output=True, timeout=20, env=os.environ)
    if result.returncode: raise RuntimeError(result.stderr.strip() or "catalog failed")
    return json.loads(result.stdout)
def sources():
    return {"combined": ("Build + CloudXR server", state / "server.log"), "proxy": ("Brev Secure Link proxy", state / "proxy.log"), "ui": ("Chooser + WebXR service", state / "ui.log"), "stun": ("Local STUN address mapping", state / "stun.log")}
class Handler(BaseHTTPRequestHandler):
    def send_bytes(self, payload, status=200, content_type="application/json"):
        self.send_response(status); self.send_header("Content-Type", content_type); self.send_header("Content-Length", str(len(payload))); self.send_header("Cache-Control", "no-store"); self.send_header("X-Content-Type-Options", "nosniff"); self.end_headers(); self.wfile.write(payload)
    def send_json(self, value, status=200): self.send_bytes(json.dumps(value).encode(), status)
    def do_GET(self):
        parsed, query = urlparse(self.path), parse_qs(urlparse(self.path).query)
        try:
            if parsed.path == "/": return self.send_bytes(page, content_type="text/html; charset=utf-8")
            if parsed.path.startswith("/webxr"):
                root = (Path(first("current.flavor")) / "build/cloudxr/cloudxr-js-samples/react/build").resolve()
                name = unquote(parsed.path.removeprefix("/webxr/") or "index.html"); target = (root / name).resolve()
                if root not in target.parents and target != root: return self.send_json({"error": "not found"}, 404)
                if target.is_dir(): target /= "index.html"
                data = target.read_bytes()
                if target.name == "index.html": data = data.replace(b"</head>", b"<script>localStorage.setItem('serverIp',location.hostname);localStorage.setItem('port','443');localStorage.setItem('proxyUrl',location.origin+'/signal');</script></head>")
                return self.send_bytes(data, content_type=mimetypes.guess_type(target.name)[0] or "application/octet-stream")
            if parsed.path == "/healthz":
                process, network = process_status(), network_status()
                healthy = process["state"] == "ready"
                if healthy and network["current"].get("enable_ice") and network["current"].get("stun_mode") == "local":
                    try: network_module.probe("127.0.0.1", network["current"]["stun_port"], network["current"]["public_ip"])
                    except Exception: healthy = False
                return self.send_json({"ready": healthy, "state": process["state"]}, 200 if healthy else 503)
            if parsed.path == "/api/status": return self.send_json({"inventory": inventory(), "process": process_status(), "ports": {"native": native_port}, "network": network_status()})
            if parsed.path == "/api/logs": return self.send_json({"sources": [{"id": key, "name": name} for key, (name, _) in sources().items()]})
            if parsed.path == "/api/log":
                source_id, allowed = query.get("id", ["combined"])[0], sources()
                if source_id not in allowed: return self.send_json({"error": "unknown log source"}, 404)
                path = allowed[source_id][1]; size = path.stat().st_size if path.exists() else 0
                raw = query.get("offset", [""])[0]; offset = int(raw) if raw.isdigit() else max(0, size - 100000)
                if offset > size: offset = 0
                with path.open("rb") if path.exists() else open(os.devnull, "rb") as stream:
                    stream.seek(offset); data = stream.read(65536); next_offset = stream.tell()
                return self.send_json({"text": data.decode(errors="replace"), "offset": next_offset, "size": size})
            return self.send_json({"error": "not found"}, 404)
        except Exception as exc: return self.send_json({"error": str(exc)}, 500)
    def do_POST(self):
        if self.headers.get("Origin") and urlparse(self.headers["Origin"]).netloc != self.headers.get("Host"): return self.send_json({"error": "cross-origin request rejected"}, 403)
        try:
            length = min(int(self.headers.get("Content-Length", "0")), 4096); form = parse_qs(self.rfile.read(length).decode()); path = urlparse(self.path).path
            if path == "/api/start":
                values = [form.get(name, [""])[0] for name in ("mode", "runtime", "js", "framework")]
                if any(name in form for name in ("stun_mode", "deployment_mode", "apple_profile")):
                    saved = network_module.settings(state)
                    values += [form.get(name, [str(saved[name])])[0] for name in ("stun_mode", "public_ip", "stun_ip", "stun_port", "media_port", "deployment_mode")]
                    values += [form.get("apple_profile", [first("apple.profile") or "apple-vision-pro"])[0]]
                result = subprocess.run([app, "start", *values], text=True, capture_output=True, timeout=90, env=os.environ)
            elif path == "/api/stop": result = subprocess.run([app, "stop"], text=True, capture_output=True, timeout=90, env=os.environ)
            else: return self.send_json({"error": "not found"}, 404)
            message = (result.stdout or result.stderr).strip()
            return self.send_json({"message": message or "done"} if result.returncode == 0 else {"error": message or "launcher command failed"}, 200 if result.returncode == 0 else 409)
        except subprocess.TimeoutExpired: return self.send_json({"error": "launcher command timed out"}, 504)
        except Exception as exc: return self.send_json({"error": str(exc)}, 400)
    def log_message(self, fmt, *args): sys.stderr.write("ui: " + fmt % args + "\n")
server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
print(f"CloudXR Experiences HTTP backend listening on 127.0.0.1:{port}", flush=True); server.serve_forever()
PY
}
serve_ui() {
  command -v haproxy >/dev/null || die "haproxy is required"
  cat > "$STATE_DIR/haproxy.cfg" <<EOF
global
  log stdout format raw local0
defaults
  log global
  mode http
  option httplog
  timeout connect 5s
  timeout client 3600s
  timeout server 3600s
  timeout tunnel 3600s
frontend cloudxr_experiences
  bind *:$UI_PORT
  acl signaling path_beg /signal
  acl websocket hdr(Upgrade) -i websocket
  acl native_signaling path_reg -i /sign_in$
  use_backend signaling if signaling
  use_backend native if websocket
  use_backend native if native_signaling
  default_backend chooser
backend chooser
  server chooser 127.0.0.1:$UI_BACKEND_PORT
backend signaling
  http-request replace-path ^/signal/[^/]+(/.*)$ \1
  http-request replace-path ^/signal(/.*)$ \1
  server runtime 127.0.0.1:49100
backend native
  server runtime 127.0.0.1:$NATIVE_PORT
EOF
  "$SELF" _http "$UI_BACKEND_PORT" >> "$UI_LOG" 2>&1 &
  local backend=$!
  trap 'kill "$backend" 2>/dev/null || true; wait "$backend" 2>/dev/null || true' EXIT INT TERM
  printf '%s\n' "$$" > "$UI_PID_FILE"
  haproxy -db -f "$STATE_DIR/haproxy.cfg" >> "$PROXY_LOG" 2>&1
}
start_ui() {
  local attempt
  if pid_alive "$UI_PID_FILE"; then sudo -n kill -TERM -- "-$(first_line "$UI_PID_FILE")" 2>/dev/null || true; sleep 0.5; fi
  rm -f "$UI_PID_FILE"
  setsid "$SELF" serve > "$UI_LOG" 2>&1 </dev/null &
  for ((attempt=0; attempt<30; attempt++)); do curl -fsS "http://127.0.0.1:$UI_PORT/" >/dev/null 2>&1 && break; sleep 1; done
  curl -fsS "http://127.0.0.1:$UI_PORT/" >/dev/null || { tail -n 40 "$UI_LOG" "$PROXY_LOG" >&2; die "UI failed to start"; }
}
setup() {
  local command mode latest
  mkdir -p "$STATE_DIR" "$FLAVOR_ROOT"
  [[ "$(uname -s)" == Linux ]] || die "Brev launch requires Linux"
  for command in curl git python3 setsid sort sudo; do command -v "$command" >/dev/null || die "$command is required"; done
  upgrade_gpu_driver
  (( REBOOT_SCHEDULED )) && return
  ensure_build_dependencies; ensure_source; catalog --refresh >/dev/null; start_ui
  note "cloudxr-lovr-sample main: $(first_line "$SOURCE_COMMIT_FILE")"
  note "open the CloudXR Experiences Secure Link in Brev"
  if ! pid_alive "$PID_FILE"; then
    mode="${CLOUDXR_DEFAULT_MODE:-webrtc}"
    latest="$(catalog --latest)" || { note "default flavor was not started; version catalog unavailable"; return; }
    (start_flavor "$mode" $latest) || note "default flavor was not started; review blockers in the chooser"
  fi
}
usage() { echo "Usage: launcher.sh [setup|catalog|start MODE RUNTIME JS FRAMEWORK [local|external PUBLIC_IP STUN_IP STUN_PORT MEDIA_PORT [direct|cloud [apple-vision-pro|ipad-pro]]]|stop|serve|restart-ui]"; }
case "${1:-setup}" in
  setup) setup ;;
  catalog) shift; catalog "$@" ;;
  start) shift; start_flavor "$@" ;;
  stop) stop_flavor ;;
  restart-ui) start_ui ;;
  serve) UI_PORT="${2:-8080}"; UI_BACKEND_PORT=$((UI_PORT + 1)); serve_ui ;;
  _http) UI_BACKEND_PORT="${2:?port}"; serve_http ;;
  _deploy) deploy_flavor "${2:?mode}" "${3:?runtime}" "${4:?js}" "${5:?framework}" "${6:-apple-vision-pro}" ;;
  help|-h|--help) usage ;;
  *) usage >&2; die "unknown command: $1" ;;
esac
