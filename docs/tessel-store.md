# Tesselix — Tessel Store and App Trust

Oct 14, 2026 · @feral keep

## Purpose and notation

This document records how Tesselix knows that an application is allowed to receive sensitive data or powers from the system, and how that trust is distributed through the Tessel Store. It is preliminary: the authorization mechanism is needed from the start, the store comes later.

It builds on the Top-Level Design and the Widget Framework. Where they differ, the Top-Level Design wins. Notation: **(agreed)**, **(suggestion)**.

## Principles (agreed)

- **Trust comes from what a process is, never from what it says.** An app ID, a path or a token presented by the app proves nothing on its own.
- **Verify content, not location.** A binary is trusted by its digest or signature, regardless of the path it runs from.
- **Verification is local and offline.** No server is consulted at launch; the store only distributes signed data.
- **Capabilities per app,** not a single "internal" level.
- **The protection is against the user's apps,** not against the user acting as administrator, except in the optional hardened mode.

## Authorization: is this process allowed? (agreed)

Every Tesselix service that hands out sensitive data or powers (compositor, data service, memory, recorder, gateway) applies the same check. It lives in one shared library so every service checks the same way.

### On connect

1. **Peer identity** from the Unix socket (`SO_PEERCRED`): PID, UID, GID.
2. **Pin the process** with a `pidfd`, so a PID reused by another process can't pass as the original.
3. **Identify the binary** through `/proc/<pid>/exe`: read its fs-verity digest from the kernel (or hash it when fs-verity is not available), and check it against the trust sources.
4. **Look up its capabilities** in the trust sources: what this binary, at this version, may ask for.
5. **Issue a session token** bound to that pidfd and the process start time, with the granted capabilities and an expiry.

### On every request

- **The request must come over the same connection,** from the same pinned process. A token copied into another process is useless there: the service checks whether the process holding it is the one it was issued to, not only whether the token is valid.
- **The capability is checked per request type.** Holding a token for the data service's system tier grants nothing in memory or the compositor.
- **Exec is detected.** A process that replaces its binary (`exec`) keeps its PID and pidfd. The service re-checks the binary's digest when the process connector reports an exec, or before sensitive requests, and drops the session if it changed.

### What makes the check hold

- **Clean launch:** internal apps are started by the compositor or session with a cleaned environment, so `LD_PRELOAD` and similar injection don't apply. (suggestion) The compositor may hand an internal app a pre-authenticated socket at start; the per-request checks still apply.
- **Yama `ptrace_scope` ≥ 1 is required,** so a process can't attach to another one that isn't its child.
- **(suggestion) The recorder and memory services run as a separate system user,** so the user's apps can't read the history files at all and reach the data only through checked sockets.

### Known limit

Code injected into a valid, running internal app passes every check, since it runs inside the right process. The defenses are the ones above: no attaching, clean launch, and separate users for the most sensitive data.

## Trust sources

### Stages (agreed)

| Stage | Trust comes from | Who can change it |
| --- | --- | --- |
| Development | Local trust store: developer keys and binary digests | The developer, through a polkit-gated tool |
| Store | Signed manifest from the Tessel Store, verified with the store's public key built into Tesselix | Only the store |
| Hardened (optional) | Verified boot and a dm-verity system partition | Nobody on the machine |

Development and store sources can be active together, so developers test local builds alongside store apps.

### Local trust store (development)

- **Root-owned and read-only for the user** (for example `/etc/tesselix/trust/`). The kernel refuses writes from the user's processes; changes go through a polkit-gated tool (`tesselix-trust add`, `revoke`) that asks for the admin password.
- **Not encrypted:** encryption hides content but doesn't stop changes. File permissions do.
- (suggestion) **Signing builds:** a dev key whose public half is in the trust store, and a `zig build` step that signs each binary, so rebuilds need no re-registration.

### Signed manifest (store)

The Tessel Store publishes a manifest, signed with the store's private key, which never leaves the store. It holds:

- **Apps, versions and their digests.**
- **Capabilities per app** (see below).
- **A version number,** so an older signed manifest can't be put back to re-trust a flawed version (rollback protection).
- **A revocation list** for apps, versions or keys no longer trusted.

The client verifies the signature with the public key built into Tesselix before using it. Who can write the local copy no longer matters: a changed manifest fails verification.

### Kernel mechanisms

- **fs-verity** on installed binaries: the kernel keeps them read-only and gives their digest instantly, so services don't hash binaries themselves.
- **Immutable attribute** (`chattr +i`) on trust files, against accidents.
- **Later, for the hardened mode:** IMA/EVM (the kernel refuses to run unsigned binaries), Secure Boot, a signed kernel, and dm-verity for the system partition, as ChromeOS and Android do.

## Capabilities (agreed)

Each app's entry in the trust sources lists what it may request. Examples:

| Capability | Grants |
| --- | --- |
| Data service: system tier | Drives, printers, installed apps |
| Personal data, read | Recent files, history, working sets, salience |
| Compositor: overlays | Drawing over other windows, highlight overlays |
| Compositor: input capture | Pick mode, capturing clicks on other windows |
| Gateway | Network access through the gateway |

- **Core Tesselix apps** get what they need; only they get compositor powers.
- **Store apps** get only the capabilities listed for them in the signed manifest.
- **Unverified apps** get reference data only, and normal windows.

## Store distribution (suggestion)

- **The manifest is fetched through the gateway,** the only process allowed on the network.
- **Whole manifest, or the part for installed apps;** never a query per launch, so the store doesn't learn when the user runs what.
- Release and signing keys are published by the store; updates and revocations arrive with the manifest or through the package manager.

## Trust levels for sandboxed and unsandboxed apps

| Level | Who | Gets | Enforced by |
| --- | --- | --- | --- |
| Verified | Core apps and store apps with capabilities | What their capabilities list | The authorization check |
| Sandboxed third-party | Flatpak apps | Reference data; system data by portal permission | The sandbox plus portal permissions |
| Unsandboxed third-party | Any other app | Reference data; no compositor powers or personal data | The compositor for powers; services for data |

An unsandboxed app can read much of the system directly (`/sys`, `/proc`, D-Bus), so for it the data-service tiers are policy. Compositor powers and the separately owned history remain real boundaries.

## Open questions

- [ ] Separate system user for the recorder and memory services: confirm.
- [ ] Sandboxing for third-party Tesselix apps: required or recommended?
- [ ] Signature format: detached `.sig` files or an ELF section.
- [ ] Capability list: final names and granularity.
- [ ] Store: hosting, developer accounts, review process, update cadence of the manifest.
- [ ] Hardened mode: whether and when to offer it.
