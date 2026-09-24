# zcode-legacy-glibc

Run the **ZCode desktop remote runtime** on RHEL 7 / CentOS 7 / Scientific Linux 7 (glibc 2.17) systems.

The ZCode desktop app ships a self-contained runtime for SSH remotes under `~/.zcode/server`. Every
x64 Linux binary in that runtime is built against glibc 2.28 and libstdc++ 3.4.21+, so on an
EL7-era host the remote server dies before the handshake with errors like:

```
/home/demo/.zcode/server/node: /lib64/libc.so.6: version `GLIBC_2.28' not found
/home/demo/.zcode/server/node: /lib64/libstdc++.so.6: version `GLIBCXX_3.4.21' not found
```

This repo builds drop-in replacements that link only against glibc 2.17 / GLIBCXX 3.4.19 and
installs them into `~/.zcode/server`, without touching system libraries, without installing RPMs,
and without rebuilding anything on the target host.

## How It Works

The desktop decides what to (re)deploy by comparing **version strings**, not file hashes:

| Component | Marker the desktop reads | Marker type | Hash checked? |
| --- | --- | --- | --- |
| `node-runtime` | `~/.zcode/server/.asset-components/node-runtime.json` | `version` | no |
| `node-pty` | `~/.zcode/server/.asset-components/node-pty.json` | `version` | no |
| `bfs`, `ripgrep`, `ugrep` | `~/.zcode/server/tools/<tool>/.version` | `version` | no |
| `server-bundle`, `glm` | `~/.zcode/server/.asset-components/<id>.json` | `sha256` | yes |

So a replacement binary is accepted as long as:

1. the file exists at the expected path, and
2. the version string in the marker still matches the version the desktop expects.

That is exactly what this patch kit does — it swaps the binaries and **never writes the markers**.
Because the replacements declare the same upstream versions the desktop expects, the desktop skips
re-uploading them on the next connection.

Replacements produced here:

| Path | Source | Built with |
| --- | --- | --- |
| `~/.zcode/server/node` | Node.js `v22.16.0` **glibc-217** build (unofficial-builds.nodejs.org) | prebuilt, sha256-verified |
| `~/.zcode/server/build/Release/pty.node` | npm `node-pty@1.2.0-beta.10` (exact upstream version) | devtoolset-11 g++, `-static-libstdc++` |
| `~/.zcode/server/tools/bfs/bfs` | upstream `bfs` 4.1.1 | devtoolset-11 gcc |
| `~/.zcode/server/tools/ugrep/ugrep` | upstream `ugrep` 7.8.4 + private static PCRE2 10.44 | devtoolset-11 g++, `-static-libstdc++` |

`ripgrep` needs no replacement: the shipped binary is already statically linked.

## When the patch is reverted

The desktop overwrites the patched binaries in exactly three situations:

1. **ZCode is upgraded** and the new manifest bumps `node-runtime` / `node-pty` / tool versions
   (the desktop re-uploads the official, glibc-2.28 builds).
2. **The asset manifest cannot be fetched** on the desktop side — the deploy then falls back to
   "legacy full deploy" and uploads everything.
3. The SSH target's *Resource download method* is switched from **Download locally, then upload**
   to **Download on remote server** in the ZCode UI. That mode verifies sha256 on the remote and
   will refuse/replace the patched binaries.

In all three cases, re-apply:

```bash
~/.zcode/legacy-glibc/scripts/apply.sh        # idempotent; picks the newest cached bundle
~/.zcode/legacy-glibc/scripts/verify.sh
```

If the versions changed, the cached bundle no longer matches and `apply.sh` stops with an explicit
message — then rebuild a bundle for the new versions (see *Building* below or run the
`Build legacy runtime bundle` GitHub Action manually).

## Prerequisites

| Item | Notes |
| --- | --- |
| glibc | 2.17 (RHEL/CentOS/SL 7) |
| shell | `bash` |
| tools | `tar`, `sha256sum`, `objdump` (binutils), `curl` (only for downloads) |
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
`.official-glibc228.bak`, then runs `verify.sh`. Bundles are artifacts only; the scripts live in
this repository, and `apply.sh` refuses to apply a bundle whose versions do not match the markers
the desktop recorded on that host.

## Commands

| Command | Purpose |
| --- | --- |
| `scripts/apply.sh [--bundle PATH] [--check] [--no-verify] [--force]` | Install the compatible binaries from a bundle (or the newest cache entry) |
| `scripts/verify.sh` | Assert GLIBC/GLIBCXX ceilings, load `pty.node`, run every tool |
| `scripts/rollback.sh` | Restore every `*.official-glibc228.bak` |
| `scripts/selfcheck.sh [--install-cron] [--remove-cron]` | Health check; optionally self-heal from the offline cache (cron install is opt-in) |

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `ZCODE_RUNTIME_ROOT` | `$HOME/.zcode/server` | Runtime directory to patch |
| `ZCL_STATE_DIR` | `$HOME/.zcode/legacy-glibc` | State, cache and logs |
| `ZCL_GLIBC_CEILING` | `2.17` | Symbol ceiling asserted by `verify.sh` |
| `ZCL_GLIBCXX_CEILING` | `3.4.19` | libstdc++ symbol ceiling asserted for `node` |

## Building

Bundles are produced by `build/package.sh`, which runs the four build scripts. They are the same
recipes used by hand on the target host and inside CI, so local and CI artifacts are comparable.

```bash
# native build on an EL7 host (devtoolset-11 + python3.8 or node-gyp@9)
ZCL_DEPS_DIR=$HOME/.zcode/legacy-glibc/build-deps build/fetch-node.sh
build/build-pty.sh && build/build-bfs.sh && build/build-ugrep.sh
build/package.sh --out dist
```

CI (GitHub Actions, **manual trigger only**) builds the same bundle inside a `centos:7` container —
see `.github/workflows/build.yml`. Nothing runs on a schedule; run it when ZCode bumps versions.

## Verified Environment

- Host: VMware VM, RHEL 7.9, kernel 3.10.0-1160, glibc 2.17, GLIBCXX up to 3.4.19
- ZCode desktop 3.14.3, remote runtime `linux-x64`
- Result: SSH workspace connects, agent runs, terminal works (real `/dev/pts` via the rebuilt
  `pty.node`), `rg` / `bfs` / `ugrep` all execute.

Details, measurements and the exact deploy logic that this kit relies on: [`docs/evidence.md`](docs/evidence.md).

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `GLIBC_2.28 not found` on connect | Official binaries were re-uploaded (one of the three triggers above) | `apply.sh` then `verify.sh` |
| `node-pty is unavailable in this runtime` in terminal | `pty.node` reverted or missing | `apply.sh` (bundle contains `pty.node`) |
| `apply.sh` says *no bundle matches the expected versions* | ZCode was upgraded and expects newer component versions | Run the `Build legacy runtime bundle` action with the new versions |
| Tools work but terminal does not | `pty.node` not installed | `~/.zcode/server/node -e "require('/home/<user>/.zcode/server/build/Release/pty.node')"` |

## License

MIT — see [`LICENSE`](LICENSE). Redistributed upstream components keep their own licenses: Node.js
(MIT and others), node-pty (MIT), bfs (Apache-2.0), ugrep (BSD-3-Clause), PCRE2 (BSD-3-Clause).
ZCode itself is proprietary; this repository ships no ZCode binaries.
