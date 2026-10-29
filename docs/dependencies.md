# Dependencies

## Rule: latest solid version (agreed, 2026-10-14)

Kuroko uses the **latest solid** version of every tool and library.

- **Solid** = a stable release (not a beta, release candidate or nightly)
  whose version line (major.minor) has been out for **at least 3 months**.
- Within a solid line, use the **newest patch release**: patches fix bugs
  without changing the API.
- A newer line that is not solid yet is not used, even if it is the stable
  channel's current release. Note it below with the date it becomes solid.
- **Upgrades are deliberate:** when a line becomes solid, upgrade in its own
  change, update this table and `docs/zig-notes.md`, and run all tests.
- **Exception:** if a dependency forces an older version, record why here.
  Before production, everything moves to the then-latest solid versions.

## Current versions

| Dependency | Used | Line released | Solid since | Next line | Solid from |
| --- | --- | --- | --- | --- | --- |
| Zig | 0.16.0 | 2026-04-14 | 2026-07-14 | 0.17.0 (2026-10-04) | 2027-01-04 |
| SDL (simulator only) | 3.4.x, newest patch (3.4.18 when written) | 2026-01-01 | 2026-04-01 | — | — |
| Inter font (atlases) | as shipped by the build machine; regenerate with `tools/fontgen` | | | | |
| Noto Sans Hebrew (fallback atlases) | 3.001 (notofonts, hinted TTF); regenerate with `tools/fontgen --hebrew` | | | | |

GPU: OpenGL ES 3.0 (Linux) and OpenGL 3.3 core (macOS), from the system's
driver (Mesa on Linux); loaded at run time, nothing to pin.

Later, for Kuroko's own Linux backend (no wlroots, see the Top-Level
Design, "Foundation"): libdrm, GBM and EGL (Mesa), libinput, libxkbcommon,
libseat, wayland-protocols (XML, for the protocol definitions). Their
versions are chosen by the same rule when the backend is built.

## How to check

- Release date of a line: the project's release notes or announcement for
  `X.Y.0`.
- Solid date: release date + 3 months.
- Newest patch: the project's tags or package manager (`brew info`,
  distribution package lists).
