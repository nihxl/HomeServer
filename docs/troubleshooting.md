# War Stories: Debugging Log

Real problems encountered while building and operating this server, documented as **Symptom → Root Cause → Resolution**. Selected for genuine technical depth rather than completeness.

---

## 1. Dashboard integration silently unreachable through reverse tunnel

**Symptom:** A self-hosted dashboard service was accessible on the local network directly, but consistently unreachable through the external reverse tunnel, while every other tunneled service worked fine.

**Root Cause:** The service's Compose file defined its own **isolated custom Docker network** with a unique subnet. Every other working service relied on Docker's default bridge network, which the tunnel's own container could reach via the bridge gateway IP. The isolated custom network had no route from the tunnel container at all.

**Resolution:** Removed the unnecessary custom network definition from the service's Compose file, allowing it to join the default bridge like the rest of the stack. Confirmed reachability with a direct `curl` test from the host to the bridge-gateway address before re-testing through the tunnel.

**Lesson:** Custom Docker networks are for genuine isolation needs. Adding one "by default" (e.g. via a downloaded example Compose file) can silently break assumptions the rest of the infrastructure depends on.

---

## 2. A single missing group membership caused three unrelated-looking failures

**Symptom:** Over the course of one session, three seemingly unrelated things failed:
1. A Spotify-Connect audio container repeatedly threw ALSA "device busy/invalid" errors.
2. The desktop's user-space audio daemon reported zero available hardware devices.
3. Manual command-line audio tests failed with confusing "invalid card index" errors, despite the kernel clearly detecting the sound hardware.

**Root Cause:** The service account did not belong to the `audio` Linux group. All `/dev/snd/*` device nodes are group-owned by `audio` with no other-user access — so *nothing* on the system, containerized or not, could actually open the hardware, even though the kernel-level driver layer (`/proc/asound/cards`) showed the hardware correctly.

**Resolution:** Added the account to the `audio` group and started a fresh login session (group membership changes don't apply to already-running sessions). All three symptoms resolved simultaneously without touching any container configuration.

**Lesson:** When multiple, seemingly-independent components fail at the same layer (all audio-related here), check for one shared root cause — usually a permissions or group-membership issue — before debugging each symptom in isolation.

---

## 3. Automation engine's SSH-based commands failing with cryptic parser errors

**Symptom:** A Docker-monitoring workflow, using an automation platform's SSH node to run `docker ps --format "{{.Names}}: {{.Status}}"`, failed immediately with an "invalid syntax" error — despite the exact same command working perfectly when run manually over SSH.

**Root Cause:** The automation platform's own templating engine also uses `{{ }}` as its expression delimiter. When the command field was in "expression mode," the platform tried to parse Docker's Go-template syntax (`{{.Names}}`) as its *own* expression language before ever sending the command to SSH — and failed, since `.Names` isn't valid in that context.

**Resolution:** Either switched the field to plain/fixed-text mode (bypassing the platform's own parser for that field), or avoided Go-template formatting entirely by using the tool's default plain-text output — sidestepping the syntax collision altogether.

**Lesson:** When embedding one tool's templating syntax inside another tool that *also* uses `{{ }}` delimiters, expect a collision. Prefer a plain-output mode over custom-formatted output when piping a command through an orchestration layer.

---

## 4. Automated commit pipeline silently losing data on push

**Symptom:** An automation pipeline was supposed to write a new file and commit + push it to a Git-synced document vault on every run. Files were being written to disk correctly, but never appearing on the remote repository.

**Root Cause:** Two compounding issues:
1. Git's author identity (`user.name`/`user.email`) had never been configured on the server, so `git commit` was failing silently inside the automation's chained shell command (`&&`) — meaning the subsequent `git push` never ran.
2. Once identity was fixed, a second failure surfaced: the remote repository had diverged (another device had pushed independently), so `git push` was rejected with a non-fast-forward error.

**Resolution:** Set git identity once, configured a default merge reconciliation strategy (`git config pull.rebase false`), and updated the automation's command chain to always run `git pull --no-edit` immediately before `git add`/`commit`/`push`, so it reconciles with the remote on every single run rather than assuming a clean fast-forward.

**Lesson:** Any automation that pushes to a repository shared with other writers must defensively pull-before-push on *every* run, not just handle the happy path — and chained shell commands (`&&`) fail silently if an early step (like a missing git identity) isn't validated first.

---

## 5. mDNS service discovery working from one client but not another, on the same network

**Symptom:** A local network service using Spotify Connect (mDNS/zeroconf-based discovery) was discoverable and controllable from a desktop client, but completely invisible to a phone client — despite both being connected to the same WiFi network, with confirmed IP reachability between them.

**Root Cause:** The server had **two active network interfaces (wired and wireless) simultaneously assigned addresses on the identical subnet**. This created ambiguous routing for multicast traffic specifically — unicast/TCP traffic (like loading a web dashboard) worked fine regardless of which interface handled it, but mDNS broadcast responses could return via an interface path some clients didn't expect, causing silent discovery failures for a subset of devices.

**Resolution:** Diagnosed by comparing interface configurations (`ip a`) and confirming both interfaces shared a subnet; designed a NetworkManager dispatcher script to enforce mutual exclusivity between the two interfaces (only one active at a time, toggled automatically based on physical Ethernet link state), eliminating the ambiguity at its source rather than patching the discovery protocol.

**Lesson:** Multicast/broadcast-based discovery protocols are far more sensitive to multi-homed network configurations than ordinary TCP traffic. "It works from one device but not another on the same network" is a strong signal to check for asymmetric or ambiguous routing, not to assume the *application* is misconfigured.

---

## 6. Container management UI unable to manage a stack that "clearly exists"

**Symptom:** A Compose stack was confirmed running correctly via the command line, but the management UI reported it as unmanageable / showed a missing-file error when trying to control it, despite the UI's own file browser showing the directory.

**Root Cause:** The management UI runs inside its own container, which only has visibility into paths explicitly bind-mounted into *its* Compose file. The target stack's actual data lived at a path outside the UI's mounted directory (a historical artifact of an earlier migration) — a symlink was created to bridge the gap at the host level, but symlinks pointing *outside* an already-mounted volume are invisible to a container, since the container's filesystem view has no knowledge of paths the host hasn't explicitly shared with it.

**Resolution:** Added the real external path as an additional, explicit bind mount directly in the management UI's own Compose file (alongside its standard managed-stacks directory), rather than relying on a host-level symlink the container couldn't see through.

**Lesson:** Symlinks are a host-filesystem concept; they don't grant a container visibility into paths that were never mounted into it in the first place. When a containerized tool needs to manage something outside its default directory, mount the real path explicitly rather than trying to alias around the boundary.
