<!--
  SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# CloudXR Experiences

Internal source for a one-click NVIDIA Brev Launchable for
[`NVIDIA/cloudxr-lovr-sample`](https://github.com/NVIDIA/cloudxr-lovr-sample).
A deployment adds an **Open CloudXR Experiences** Secure Link to its Brev page.
That authenticated HTTPS entry point opens a chooser where a user can:

- switch between CloudXR.js/WebXR and the Apple native client;
- independently select CloudXR Runtime, CloudXR.js, and Apple CloudXR Framework versions;
- choose Original runtime defaults or optional Cloud deployment with ICE/STUN;
- choose AVP (`apple-vision-pro`) or iPad (`ipad-pro`) for Apple native clients;
- build a requested flavor on demand and reuse completed flavors from the cache;
- follow and search build, Runtime, chooser, and Secure Link proxy logs.

The LÖVR sample is not version-selectable. Every deployment action fetches the
latest public `main`, records the exact commit, and uses that commit in the
flavor cache key. The validated baseline when this launcher was written is
`6b30ddc1c20117a414d2eb5068686ad6b0fe3a31` (release 1.2.0).

The default branch also publishes an internal GitLab Pages preview generated
from the same `src/ui.html`. Its browser-side mock API makes client selection,
version selection, deployment phases, and logs interactive without a Brev VM.
The green preview banner identifies all simulated data; no build, GPU workload,
or CloudXR stream runs. [Open the live UI preview](https://cloudxr-brev-f449d6.gitlab-master-pages.nvidia.com/).

## Brev Launchable configuration

- **Name:** `CloudXR Experiences`
- **Software:** VM Mode; Jupyter disabled
- **Source:** `I don't have any code files`
- **Setup script:** paste all of generated `launch.sh`; retain its exact
  `#!/bin/bash` first line
- **Disk:** at least 100 GiB; every cached source/runtime/client flavor has an
  isolated worktree and build output
- **Instance:** Ubuntu 22.04+ x86_64 with an NVIDIA graphics GPU and NVENC;
  setup ensures driver 580+
- **Secure Link:** name it `Open CloudXR Experiences`, target internal HTTP port
  `8080`, and enable **Show as CTA on the deployment page**
- **Access:** restrict the direct media/native ports to the deployer's client IPs

Jupyter is intentionally disabled so the CloudXR Secure Link is the primary
experience on the deployment page. Brev terminates HTTPS on the generated
Secure Link URL; the VM only serves HTTP on internal port 8080, so there is no
port or certificate conflict with Jupyter or another launchable. See the
official [Brev Launchables guide](https://docs.nvidia.com/brev/concepts/launchables)
for Secure Link configuration.

The on-demand build downloads NVIDIA CloudXR Runtime and CloudXR.js artifacts
from NGC. Those components are governed by the NVIDIA CloudXR Software License
Agreement; using a flavor is subject to those NVIDIA terms, independently of
this launcher's Apache-2.0 source license.

The Secure Link carries chooser/client HTTP and WebSocket signaling, so ports
8080, 443, 48322, and Runtime port 49100 do not need direct public firewall
rules. Allow the following direct ports in both the provider firewall and Brev
networking. They follow the official
[CloudXR network setup](https://docs.nvidia.com/cloudxr-sdk/latest/requirement/network_setup.html).

| Port | Protocol | Mode | Purpose |
|---|---|---|---|
| 47998 | UDP | Both | WebRTC media or Apple native video |
| 48010 | TCP | Apple | Native signaling |
| 47999, 48000, 48002, 48005, 48008, 48012 | UDP | Apple | Input, audio, microphone, and video channels |

For WebXR, the launcher follows the official CloudXR.js HAProxy topology but
lets Brev own TLS. HAProxy listens on internal HTTP port 8080, sends chooser
and `/webxr/` requests to the local UI service, and forwards same-origin
`/signal/<secure-link-host>/<SDK-path>` WebSocket upgrades to the Runtime at
`ws://localhost:49100/<SDK-path>`, preserving paths such as `/sign_in`. The
browser therefore uses the Secure Link's normal NVIDIA/Brev certificate and
does not need a public-IP URL or self-signed certificate acceptance. See the
official
[CloudXR.js proxy setup](https://docs.nvidia.com/cloudxr-sdk/latest/usr_guide/cloudxr_js/proxy_setup.html).

## Launch parameters

| Name | Default | Purpose |
|---|---|---|
| `NV_CXR_ENDPOINT_IP` | detected with `api.ipify.org` | Public IP advertised by CloudXR Runtime to clients |
| `NV_CXR_MEDIA_PORT` | `47998` | Public UDP media port advertised by CloudXR Runtime |
| `CLOUDXR_UPGRADE_GPU_DRIVER` | `1` | Ensure Ubuntu's recommended NVIDIA driver is 580+ |
| `CLOUDXR_DEFAULT_MODE` | `webrtc` | Initial flavor: `webrtc` or `apple` |

On every launcher setup, it discovers Runtime and CloudXR.js releases through
the public NVIDIA NGC API and Framework releases from
`NVIDIA/cloudxr-framework` Git tags. Results are cached in
`~/.cache/cloudxr-experiences/versions.json` and the last successful discovery
remains available if either service is temporarily unreachable. No credential
is needed for these public catalogs. Setup automatically starts the selected
mode with the newest discovered component versions. Inputs are strictly
validated before reaching the upstream build. The runtime and active client
must share a major version. Current WebXR
flavors also require Runtime 6.0.5+ (`auto-webrtc`) and CloudXR.js 6.1.0+ (GA).
Runtime archive names are also resolved from each NGC version's live file
metadata, so architecture qualifiers such as 6.2.3's `Linux-amd64` do not need
launcher updates.

By default, setup follows the same reboot-safe pattern as `xr-ai-brev`: if the
loaded driver is older than 580, it installs Ubuntu's recommended compatible
driver plus matching graphics and NVENC libraries, enables a systemd
continuation, and schedules one reboot. A persistent guard prevents reboot
loops if the new kernel driver does not load. Set
`CLOUDXR_UPGRADE_GPU_DRIVER=0` only when the image manages its own driver.
For provider-managed images that load a kernel driver without an Ubuntu driver
metapackage, setup derives the branch from `/proc/driver/nvidia/version` and
installs matching utilities, Vulkan/GL, and NVENC userspace libraries.

## Flavor behavior

A server flavor is keyed by:

```text
latest LÖVR main commit + Runtime version + CloudXR.js version
```

On first use the launcher creates an isolated Git worktree, installs the LÖVR
build dependencies and matching NVIDIA Vulkan/NVENC libraries, asks the
upstream `build.sh` for the selected Runtime and CloudXR.js packages, routes
WebXR signaling through the Brev Secure Link, forces the relative
`plugins/nvidia` path so LÖVR plugin discovery works from a hidden cache
directory, and makes a Release
build. The resulting server and browser assets are shared by Apple and WebRTC;
switching client mode only restarts LÖVR with the appropriate device-profile
flag. New upstream `main` commits or Runtime/CloudXR.js selections intentionally
create new cache entries.

The **Deployment mode** selector keeps the original behavior available. New state
uses Original mode, leaving ICE to the selected runtime profile and starting no
local STUN service. Cloud mode enables ICE and configures STUN before runtime
startup. It supports an external STUN IPv4 address or a loopback-only local
responder. The local responder advertises the detected instance public IPv4
(or the configured override) while preserving each source UDP port. This
requires 1:1, port-preserving cloud NAT and reachable media ports; the responder
is not a relay. It prefers the EC2 instance public address and falls back to
`api.ipify.org`. Keep UDP access controls configured for the negotiated media
path. Changing the chooser does not change provider firewall rules.

Cloud native WebSocket upgrades are forwarded from the Secure Link to native
runtime port 48010. Use `remoteSecure` with the Secure Link hostname and system
certificate validation; Brev link access must permit that client. Original
Apple mode continues to show the instance IP and native signaling port.
Authentication and TLS at the Secure Link remain Brev's responsibility.

The Apple device selector persists its AVP/iPad preference separately from
networking and SDK versions. Both Original and Cloud modes use it. WebXR always
uses `auto-webrtc`, preserving the saved Apple choice for a later switch back.
`auto-native` is not currently offered in the selector. Apple Framework version
selection remains independent of the device profile.

`GET /api/status` includes saved and current networking plus requested/effective
profiles. `/healthz` returns 200 only for a ready managed runtime and checks the
local STUN responder when enabled; it does not establish a full client media
session. Local STUN has its own incremental log source. Settings and profiles
are validated before stopping an active deployment.

For Apple mode, the Framework selector controls the client release link and
the recorded end-to-end flavor. The Framework itself must be built into an
Apple app on macOS/Xcode; it cannot be built on the Linux Brev server. The
server build is reused when the client mode or Apple Framework selection changes.
See the official
[CloudXR Framework guide](https://docs.nvidia.com/cloudxr-sdk/latest/usr_guide/cloudxr_framework/index.html)
and [`NVIDIA/cloudxr-framework`](https://github.com/NVIDIA/cloudxr-framework).

CloudXR components from the same major release are generally compatible across
minor and patch versions. The current release notes specifically state that
CloudXR.js 6.1.0 and 6.2.0 work with Runtime 6.x. Review the official
[compatibility and release notes](https://docs.nvidia.com/cloudxr-sdk/latest/release_notes/release_notes.html)
when intentionally mixing releases.

## Logs and lifecycle

`NV_CXR_FILE_LOGGING=false` sends Runtime diagnostics to the combined server
stream. Secure Link proxy and chooser/WebXR request logs are separate selectable
sources; reads are bounded and incremental. Once the Runtime startup marker is
observed, the launcher persists `ready` independently of log retention so a
long-running session cannot regress to `starting` as output grows.

Deploy validates the requested versions and hardware before stopping the active
flavor. The detached action then fetches current LÖVR main, builds or reuses the
flavor, serves the WebXR client when selected, and starts LÖVR headlessly.
Stop terminates the managed process group and clears only its stale Runtime
lock. CloudXR uses the launcher-owned `xdg-runtime` directory so a missing
login-session runtime directory cannot prevent Monado from creating its PID
file. Before starting CloudXR, the launcher adapts the sample's NVIDIA Vulkan
ICD to EGL for headless VMs and verifies that Vulkan sees the NVIDIA GPU.
Logs and cached builds remain under `~/.cache/cloudxr-experiences`.

Logs can include hostnames, client addresses, application messages, and errors;
review them before sharing.

## Development and CI

Edit the readable sources, then run validation without requiring publication:

```bash
python3 -m unittest discover -s tests -v
```

The sources are intended to live at `cloudxr-brev/` within
`NVIDIA/cloudxr-lovr-sample`. The small bootstrap downloads only these four files
from `cloudxr-brev/src/`: `launcher.sh`, `ui.html`, `cloud-network.py`, and
`cloud-runtime.lua`. No source archive or whole-repository checkout is needed
for launcher installation. The later sample build continues to fetch its own
latest `main`, independently of the pinned launcher revision.

After publishing the directory to GitHub, check out that source revision and
build the paste-ready script from the `cloudxr-brev/` directory:

```bash
python3 scripts/build_launch.py --revision <full-40-character-GitHub-commit-SHA>
```

Alternatively set `CLOUDXR_LAUNCHER_REVISION` to the full SHA. The builder rejects
branch names, tags, and abbreviated SHAs. It compares all four files at the
pinned public GitHub URLs against the local files before writing `launch.sh`
and `launch.sh.sha256`. Missing/unpublished files, mismatched source revisions,
or HTTPS failures prevent release generation. `--repository owner/repository`
and `--source-path directory/src` support an alternate GitHub location.

Do not edit or commit generated `launch.sh`. It includes the full revision,
per-file SHA-256 checksums and lengths, and bootstrap logic only, with the same
16 KiB size check. The launcher/UI/helper sources are not compressed or embedded.
A freshly generated script is an updated launcher release; existing scripts
remain pinned. Publish the files before distributing the generated bootstrap.

On the instance, the bootstrap verifies a cached installation under
`~/.cache/cxr-launcher/<full-commit-SHA>/` on each invocation. A valid cache runs
without network access. Missing or modified cache files trigger reinstallation.
All downloads go into a private staging directory, and each file must match its
pinned length and checksum before the complete directory is promoted into place.
A filesystem lock serializes concurrent installations. Failed downloads clean
up staging and preserve any existing cache. Arguments are forwarded literally
to the launcher. `CLOUDXR_LAUNCHER_CACHE` optionally overrides the cache root;
application state, settings, logs, and builds remain in their existing location.

CI always validates the source, bootstrap syntax and size, mocked HTTP downloads,
checksum/failure handling, cache repair and reuse, concurrent installation,
argument forwarding, runtime configuration, and the local UI API. Its download
tests use a local mock server; they do not require a published GitHub revision.

Set the GitLab CI variable `CLOUDXR_LAUNCHER_REVISION` to a published GitHub SHA to
enable the separate packaging and publication jobs. These jobs verify the
published files and retain `launch.sh` plus its checksum for one week. Merge
requests, tags, and the default branch can publish verified artifacts to the
GitLab Generic Package Registry under `cloudxr-experiences`. Without that pin,
source validation and the UI preview still run, and no deployable bootstrap is
published. Packaging fails if the checkout differs from the configured GitHub
revision. In a future upstream CI job, run the same command with its full
published GitHub commit SHA.

Provider testing should cover an L40/L40S or supported Ada/Blackwell GPU, a
compute-only GPU that must be rejected, first builds of every listed version,
cached cross-mode switching, the Brev Secure Link CTA and WebSocket route, all
direct TCP/UDP firewall rules, Apple native clients, Meta Quest, and PICO 4
Ultra. NVIDIA documents current
server hardware and driver requirements in
[CloudXR Runtime Requirements](https://docs.nvidia.com/cloudxr-sdk/latest/requirement/runtime_req.html).
