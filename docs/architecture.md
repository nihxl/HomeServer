# System Architecture

## 0. Hardware Constraints (and why they matter)

This entire stack runs on a single repurposed laptop, not a purpose-built server:

| Component | Spec |
|---|---|
| CPU | Dual-core mobile processor (2014-era, 4 threads) |
| RAM | 8GB (with a 4GB swapfile added for headroom) |
| Storage | 500GB consumer SSD |
| GPU | None usable for compute (no working Linux drivers) |

Several architectural decisions in this repo are directly shaped by these constraints:
- **Beszel** was chosen over Netdata for monitoring specifically because Netdata's per-second granularity carries meaningfully more overhead on limited RAM.
- **A single-purpose audio container** (librespot alone) replaced an initial three-container music stack (hub + local-library server + Spotify client) once device contention and unnecessary resource use on constrained hardware made the simpler design the better one.
- **Machine learning workloads** (photo library semantic search) run CPU-only, with realistic expectations set for indexing time on a library of ~2,500 items.
- **A monitored swapfile** was added as a safety margin after observing RAM pressure under concurrent workloads, rather than over-provisioning services "just in case."

Building reliably within real constraints — rather than assuming unlimited headroom — has been as much a part of this project as the services themselves.

## 1. Why Linux Mint

The host runs **Linux Mint (Cinnamon)** rather than a headless-only distro like Debian or a dedicated hypervisor OS. This was a deliberate trade-off:

- The hardware is a repurposed laptop, so a full desktop environment enables local troubleshooting (audio debugging, direct console access) without needing a second machine or always relying on SSH.
- Mint's Ubuntu/Debian base means broad compatibility with Docker, standard `apt` tooling, and NetworkManager — all used extensively throughout this setup.
- The trade-off is a small amount of idle resource overhead from the desktop session versus a headless server OS — acceptable given the hardware's constraints are RAM-bound, not CPU-bound, for this workload.

## 2. Stack Management — Dockge

All services are defined as individual `docker-compose.yaml` stacks under a common directory (`/opt/stacks/<service>/`), managed through **Dockge**, a lightweight web UI for Compose stack lifecycle management (start/stop/logs/recreate).

**Key operational detail:** Dockge itself runs in a container, and it can only see/manage directories that are explicitly bind-mounted into *its own* compose file. Any stack whose real data lives outside the conventional `/opt/stacks/` path (for historical or migration reasons) must have that path added as an additional volume mount on Dockge's own service definition — otherwise it's invisible to the UI even if the container itself is running fine. This was discovered and fixed for a stack that had drifted to a non-standard path during initial setup.

## 3. Network Design

### 3.1 External access model
Remote/external access to every service is provided exclusively through a **Cloudflare Zero Trust Tunnel** (`cloudflared` container). This means:
- No inbound ports are opened on the router.
- No dynamic DNS is required.
- Access can be further gated per-subdomain with Cloudflare Access policies (email OTP, etc.) for sensitive services.

### 3.2 How `cloudflared` reaches containers
A key architectural discovery made during setup: `cloudflared` does **not** need to be attached to the same custom Docker network as a target service. It only needs the target service to **publish its port to the host** (`ports:` in the compose file). `cloudflared` then reaches it via:

`http://<docker-bridge-gateway-ip>:<published-port>`


The Docker bridge gateway IP is a fixed, predictable address on the default `docker0` network, reachable from any container on the host regardless of which custom network(s) it's also attached to. This is the pattern used for every tunneled service in this deployment — **not** per-service network bridging.

**Consequence of this design:** a dashboard service was initially unreachable through the tunnel because its compose file defined a fully isolated custom network with no route to the host bridge. The fix was to remove the unnecessary custom network entirely and let the service join the default bridge like everything else — restoring the working pattern rather than trying to bridge two isolated networks together.

### 3.3 Dual-interface subnet conflict
The host has both a wired and wireless network interface active simultaneously, historically both assigned addresses on the *same* subnet. This created ambiguous routing for multicast/broadcast-dependent protocols (mDNS/zeroconf), which manifested as a service being discoverable from some clients on the LAN but not others, despite all clients being on the same physical network.

**Resolution:** a NetworkManager dispatcher script (`/etc/NetworkManager/dispatcher.d/`) that enforces mutual exclusivity — enabling the wireless interface only when the wired interface goes down, and vice versa — ensuring only one interface is ever active on that subnet at a time.

## 4. Service Networking Summary

| Concern | Pattern used |
|---|---|
| External access | Cloudflare Tunnel → Docker bridge gateway → published container port |
| Inter-container communication (e.g. app ↔ database) | Default Compose-generated per-stack network |
| Dashboard container control | Docker socket mount (explicit read-write trust boundary, documented and access-gated) |
| VPN-scoped traffic (planned) | `network_mode: "service:<vpn-container>"` pattern for routing a single service's traffic through a WireGuard tunnel without affecting other services |

## 5. Storage Layout

- OS and most container configs/appdata live on the primary system partition.
- Bulk media (photo/video libraries) lives on dedicated, separately-mounted partitions, referenced via `UUID=` entries in `/etc/fstab` rather than device names (`/dev/sdX`), since device letters are not guaranteed stable across reboots.
- A small number of services intentionally live outside the standard stack directory for historical/migration reasons and are explicitly bind-mounted into the management UI's own container to remain manageable (see Section 2).

## 6. Permissions Model

No single server-wide `PUID`/`PGID` convention was enforced from the start — this is a documented area for future improvement. Instead, permission issues were resolved per-service as they surfaced:
- Bind-mounted data directories were `chown`'d to match a container's internal UID after an image update changed that UID.
- Hardware device access (audio) required adding the service account to the appropriate Linux group (`audio`) rather than running the relevant container as root.
- Docker socket access (for dashboard container-control and automated-update features) was granted deliberately and narrowly, with the trust trade-off documented rather than assumed.

**Planned improvement:** standardize on `PUID`/`PGID` environment variables (or explicit `user:` directives) across all new stacks going forward, to eliminate this class of bug at the source rather than fixing it reactively per incident.
