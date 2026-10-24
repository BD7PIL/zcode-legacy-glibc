# zcode-legacy-glibc

Run the **ZCode desktop remote runtime** on RHEL 7 / CentOS 7 / Scientific Linux 7 (glibc 2.17) systems.

The ZCode desktop app ships a self-contained runtime for SSH remotes under `~/.zcode/server`. Every
x64 Linux binary in that runtime is built against glibc 2.28, so on an EL7-era host the remote
server dies before the handshake with errors like:

```
/home/demo/.zcode/server/releases/3.16.3-linux-x64-.../runtime/node: /lib64/libc.so.6: version `GLIBC_2.28' not found
/home/demo/.zcode/server/releases/3.16.3-linux-x64-.../runtime/node: /lib64/libstdc++.so.6: version `GLIBCXX_3.4.21' not found
```

This repo builds drop-in replacements that link only against glibc 2.17 / GLIBCXX 3.4.19 and
installs them into `~/.zcode/server`, without touching system libraries, without installing RPMs,
and without rebuilding anything on the target host. Since ZCode 3.16 the desktop refuses nothing
and instead **warns and installs anyway** ("Continuing installation or connection"), so an
unpatched host fails during bootstrap on every connect — this kit pre-seeds or repairs the tree.

## How It Works

The kit supports **both runtime layouts** the desktop has used (`scripts/layout.sh` detects which):

| | new: **source server** (desktop ≥ 3.16) | old: **component assets** (desktop ≤ 3.15) |
| --- | --- | --- |
| entry point | `bin/zcode` → `current.json` → `releases/<id>/runtime/` | `node zcode-server.cjs` at the root |
| what the desktop re-checks | `current.json` (`version`, `archiveSha256`) + `run/status.json`; component sha256 only while it installs its own archive | version markers: `.asset-components/*.json`, `tools/*/.version` (never hashed) |
| kit's move | install the official tree once, then swap binaries **inside the release dir**; `current.json` stays the official identity the desktop wrote | swap binaries, **never write the markers** |

Replacements produced here:

| Bundle file | Installed to (new layout) | (old layout) | Source | Built with |
| --- | --- | --- | --- | --- |
| `node` | `releases/<id>/runtime/node` | `node` | Node.js `v22.16.0` **glibc-217** build (unofficial-builds.nodejs.org) | prebuilt, sha256-verified |
| `pty.node` | `releases/<id>/runtime/node_modules/node-pty/prebuilds/linux-x64/pty.node` | `build/Release/pty.node` | npm `node-pty` (version the runtime bundles; 1.1.0 as of 3.16.3) | devtoolset-11 g++, `-static-libstdc++` |
| `koffi.node` | `releases/<id>/runtime/node_modules/koffi/build/koffi/linux_x64/koffi.node` | — | npm `koffi` 2.15.6 (FFI used by `@mbears/opentui-core`) | devtoolset-11 g++, `-static-libstdc++` |
| `bfs` | `releases/<id>/runtime/tools/bfs/bfs` | `tools/bfs/bfs` | upstream `bfs` 4.1.1 | devtoolset-11 gcc |
| `ugrep` | `releases/<id>/runtime/tools/ugrep/ugrep` | `tools/ugrep/ugrep` | upstream `ugrep` 7.8.4 + private static PCRE2 10.44 | devtoolset-11 g++, `-static-libstdc++` |

`ripgrep` needs no replacement: the shipped binary is statically linked.

On a **fresh legacy host** (no runtime at all), `apply.sh` bootstraps first:
`bootstrap-source-server.sh` downloads the official archive from the release CDN, verifies its
sha256, and runs the desktop's own `bin/zcode update --from-archive` under the glibc-217 node —
so `current.json`, `install.json` and `releases/<id>/` are written by upstream code, not
reimplemented here. The bundle swaps then apply on top.

## When the patch is reverted

The desktop overwrites the patched binaries in exactly three situations:

1. **ZCode is upgraded** and reinstalls the source server (new `current.json`, new release dir).
2. **The asset manifest cannot be fetched** on the desktop side — the deploy then falls back to
   "legacy full deploy" and uploads everything (old layout).
3. The SSH target's *Resource download method* is switched to **Download on remote server**
   (old layout) — that mode verifies sha256 on the remote and refuses patched binaries.

In all three cases, re-apply:

```bash
~/.zcode/legacy-glibc/scripts/apply.sh        # newest cached bundle; explicit about version mismatches
~/.zcode/legacy-glibc/scripts/verify.sh
```

`apply.sh` refuses to apply a bundle whose versions do not match the installed tree — that is the
signal that ZCode moved on and a new bundle is needed. Since the CI now **follows upstream
automatically** (below), the matching bundle usually already exists as a release.

## Prerequisites

| Item | Notes |
| --- | --- |
| glibc | 2.17 (RHEL/CentOS/SL 7) |
| shell | `bash` |
| tools | `tar`, `sha256sum`, `objdump` (binutils), `curl` (only for bootstrap/discovery) |
| disk | ~150 MB for `node` + build products |

No `yum install`, no system library replacement, no container runtime required.

## Install

```bash
# 1. put the kit somewhere on the legacy host (any path works)
git clone https://github.com/BD7PIL/zcode-legacy-glibc.git ~/.zcode/legacy-glibc

# 2. fetch a bundle and apply it
mkdir -p ~/.zcode/legacy-glibc/cache
curl -L -o ~/.zcode/legacy-glibc/cache/zcode-legacy-glibc-latest.tar.gz \
  https://github.com/BD7PIL/zcode-legacy-glibc/releases/latest/download/zcode-legacy-glibc-<tag>.tar.gz
~/.zcode/legacy-glibc/scripts/apply.sh
```

`apply.sh` backs up every file it replaces next to the original with the suffix
`.official-glibc228.bak`, then runs `verify.sh`.

## Commands

| Command | Purpose |
| --- | --- |
| `scripts/apply.sh [--bundle PATH] [--check] [--no-verify] [--force]` | Install the compatible binaries from a bundle (or the newest cache entry); bootstraps a fresh host when no runtime exists |
| `scripts/verify.sh` | Assert GLIBC/GLIBCXX ceilings, load and **spawn** `pty.node`, load koffi, run every tool |
| `scripts/rollback.sh` | Restore every `*.official-glibc228.bak` |
| `scripts/bootstrap-source-server.sh --zcode-version V --node PATH` | Fresh install of the official source-server tree via the CDN + desktop's own updater |
| `scripts/discover-source-server.sh` | Probe the CDN for a release newer than the repo's newest tag; print component versions read from the archive |
| `scripts/selfcheck.sh` | Manual health check; replays the newest cached bundle when the runtime is broken (no cron is installed by this kit) |

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `ZCODE_RUNTIME_ROOT` | `$HOME/.zcode/server` | Runtime directory to patch |
| `ZCL_STATE_DIR` | `$HOME/.zcode/legacy-glibc` | State, cache and logs |
| `ZCL_SOURCE_CDN` | overseas CDN, domestic mirror fallback | Where bootstrap/discovery fetch releases |
| `ZCL_GLIBC_CEILING` | `2.17` | Symbol ceiling asserted by `verify.sh` |
| `ZCL_GLIBCXX_CEILING` | `3.4.19` | libstdc++ symbol ceiling asserted for `node` |

## Building

Bundles are produced by `build/package.sh`, which runs the build scripts. They are the same
recipes used by hand on the target host and inside CI, so local and CI artifacts are comparable.

```bash
# native build on an EL7 host (devtoolset-11 + python3.8 or node-gyp@9)
ZCL_DEPS_DIR=$HOME/.zcode/legacy-glibc/build-deps build/fetch-node.sh
build/build-pty.sh && build/build-koffi.sh && build/build-bfs.sh && build/build-ugrep.sh
build/package.sh --out dist
```

## CI — automatic upstream following

`.github/workflows/build.yml` runs hourly (octg-style):

1. **detect** — `scripts/discover-source-server.sh` probes the CDN forward from the newest
   `v<zcode>-<node>` release tag (bounded semver horizon), downloads the newest hit's archive and
   reads the real component versions (`nodeVersion`, node-pty, koffi, bfs, ugrep) out of it.
2. **gate** — a Release tag is the build identity: if `v<zcode>-<node>` already exists, the chain
   skips. One version is built once, never silently rebuilt.
3. **build** — same centos:7 container, same symbol-ceiling assertions (now including koffi),
   then publishes the release.

Manual `workflow_dispatch` pins the versions and bypasses discovery (use it to rebuild or to
backfill a version the probe horizon missed). Nothing about the release channel is automatic
beyond this: bundles are artifacts + releases, apply always happens explicitly on the host.

## Verified Environment

- Host: VMware VM, RHEL 7.9, kernel 3.10.0-1160, glibc 2.17, GLIBCXX up to 3.4.19
- ZCode desktop 3.14.3 (component-assets layout) and 3.16.3 (source-server layout), remote runtime `linux-x64`
- Result 3.16.3: SSH workspace connects, `bin/zcode --version` → 3.16.3, daemon reaches
  `state:"ready"` with `run/status.json` + `run/ingress-token`, terminal works (real `/dev/pts`
  via the rebuilt `pty.node`), `rg` / `bfs` / `ugrep` all execute.
- Known gap: without a koffi replacement, `@mbears/opentui-core` cannot load (official koffi
  needs glibc 2.28, its musl build is dynamically linked) — TUI-dependent features degrade until
  a bundle with the rebuilt koffi is applied.

Details, measurements and the exact deploy logic that this kit relies on: [`docs/evidence.md`](docs/evidence.md).

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `GLIBC_2.28 not found` on connect | Official binaries were re-uploaded (one of the three triggers above) | `apply.sh` then `verify.sh` |
| `apply.sh` says *tree has X, bundle provides Y* | ZCode moved to a newer release than the bundle | Let CI build it (hourly) or dispatch the workflow with the new versions |
| `node-pty is unavailable in this runtime` in terminal | `pty.node` reverted or missing | `apply.sh` (bundle contains `pty.node`) |
| TUI-dependent feature fails, log mentions `opentui` or `koffi` | koffi not replaced yet (bundle predates koffi support) | Apply a bundle that contains `koffi.node` |
| Tools work but terminal does not | `pty.node` not installed | `~/.zcode/server/bin/zcode` version check then `verify.sh` |

## License

MIT — see [`LICENSE`](LICENSE). Redistributed upstream components keep their own licenses: Node.js
(MIT and others), node-pty (MIT), koffi (MIT), bfs (Apache-2.0), ugrep (BSD-3-Clause), PCRE2
(BSD-3-Clause). ZCode itself is proprietary; this repository ships no ZCode binaries.
