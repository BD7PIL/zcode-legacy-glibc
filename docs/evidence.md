# Evidence

Everything this kit relies on was verified against the real components rather than assumed.
This file records what was checked, on which version, and how to re-check it.

Test environment:

- Host: VMware VM `V93000VM`, RHEL 7.9 (Maipo), kernel `3.10.0-1160.el7.x86_64`, glibc **2.17**,
  libstdc++ ceiling **GLIBCXX_3.4.19**
- ZCode desktop **3.14.3** (`@zcode/desktop`, vendor z.ai / Zhipu), remote platform `linux-x64`
- Remote runtime root: `~/.zcode/server`

## 1. Why the official runtime fails

| Binary | Required by official build | Host provides |
| --- | --- | --- |
| `~/.zcode/server/node` (Node v22.16.0) | `GLIBC_2.28`, `GLIBCXX_3.4.21` | glibc 2.17, GLIBCXX 3.4.19 |
| `~/.zcode/server/build/Release/pty.node` | `GLIBC_2.28`, `GLIBCXX_3.4.22` | same |
| `~/.zcode/server/tools/bfs/bfs` | `GLIBC_2.28` | same |
| `~/.zcode/server/tools/ugrep/ugrep` | `GLIBC_2.28`, `GLIBC_2.25` | same |
| `~/.zcode/server/tools/ripgrep/rg` | statically linked | fine |

Symptom on the desktop: `Stream closed before handshake completed (exit code 1; stderr: ...
version 'GLIBC_2.28' not found ...)`.

## 2. How the desktop decides to (re)deploy

Verified by reading the shipped host bundle (`app.asar`, member `/out/host/chunk-6KPGI2BV.js`):

- `shouldDeployVersionedComponent` (`~/.zcode/server` = `M`):

  ```js
  function mo(e,t){if(t.force)return{shouldDeploy:!0,reason:"force deploy requested"};
    if(!await e.exists(t.remotePath))return{shouldDeploy:!0,...};
    if(!t.expectedVersion)return t.fallbackDeployWhenVersionUnknown?{shouldDeploy:!0,...}:{shouldDeploy:!1};
    let r=await Qe(e,t.componentId);
    return r? r.id!==t.componentId?{...}:
             r.platformArch!==t.platformArch?{...}:
             ot(r.version)!==ot(t.expectedVersion)?{shouldDeploy:!0,reason:`remote version mismatch ...`}:
             {shouldDeploy:!1}
           :{shouldDeploy:!0,reason:`remote component meta missing ...`}}
  ```

  The remote "meta" is a JSON file the desktop wrote earlier at
  `~/.zcode/server/.asset-components/<componentId>.json`, containing `id`, `platformArch` and
  `version`. **Only the version string is compared - the binary is never hashed** for
  `node-runtime` and `node-pty`.

- Tools use the same pattern with `tools/<tool>/.version` (function `deployRuntimeTools`, `Ft`):

  ```js
  let p=""; try{p=(await e.readFile(h)).trim()}catch{p=""}
  if(p===c){ if(await e.exists(g)){ ...skip... } }
  ```

- `checkRemoteAssetComponentIdentity` (function `Xe`, sha256 based) is called for exactly two
  components: `server-bundle` and `glm`. No sha256 gate exists for node/pty/tools.

- The launch command is fixed:

  ```js
  `${ZCODE_ENV}="desktop-attached-remote" ZCODE_SERVER_RUNTIME_ROOT="$HOME/.zcode/server" ...
   ~/.zcode/server/node ~/.zcode/server/zcode-server.cjs`
  ```

## 3. The only three ways the patch is reverted

1. **ZCode upgrade with new component versions.** The manifest is fetched per app version:
   `https://cdn-zcode.z.ai/zcode/electron/releases/<appVersion>/manifest-linux-x64.json`
   (fallback `<base>/manifest-linux-x64.json`). If the new manifest declares a newer
   `node-runtime`/`node-pty`/tool version, the desktop re-uploads the official binary and rewrites
   the marker. (Verified: the 3.14.3 manifest lists `node-runtime v22.16.0+7d37ff1b4544`,
   `node-pty v1.2.0-beta.10+524740883ddc`, `bfs v4.1.1-2+e6c27efd81e0`,
   `ripgrep v14.1.1-1+19722ce90d71`, `ugrep v7.8.4-1+bdfe50afb58f`; version strings are normalized
   by stripping the `+hash` suffix, which is why the marker holds `v22.16.0`.)
2. **Manifest unavailable on the desktop side.** `deployNodeRuntime` passes
   `fallbackDeployWhenVersionUnknown: true`, so with no expected version the desktop performs the
   "legacy full deploy" and uploads everything.
3. **Resource download method switched to "Download on remote server"** (SSH target setting,
   `assetInstallMode="remote-download"`). That installer verifies sha256 on the remote twice and
   hard-fails on mismatch, so it will not accept patched binaries. Keep the default
   **"Download locally, then upload"** (`local-download-upload`).

## 4. Assets are public, but per-desktop-version

- `HEAD https://cdn-zcode.z.ai/zcode/electron/releases/3.14.3/manifest-linux-x64.json` → `200`
- `HEAD .../components/linux-x64/node-runtime/v22.16.0%2B7d37ff1b4544.tar.gz` → `200`,
  `application/x-gzip`, 43,836,686 bytes (`+` must be percent-encoded as `%2B`)
- Directory listing: not available (`NoSuchKey`), so the mirror route below needs a known version.

## 5. Optional future route: serve our own assets to the desktop

The desktop reads the asset base URL from an environment variable that is **not** gated to dev
builds:

```js
function jc(e,t={}){return process.env[e]?.trim()||t[e]?.trim()||void 0}
function ig(e={}){let t=e.overrideBaseUrl?.trim(); if(t)return[sg(t)]; ...}
// call site: resolveRemoteAssetCdnBaseUrl -> ZCODE_REMOTE_ASSET_CDN_BASE_URL
```

Setting `ZCODE_REMOTE_ASSET_CDN_BASE_URL=https://<mirror>/zcode/electron/releases` (no trailing
version segment, or exactly the app version) on the desktop makes it fetch
`<mirror>/<appVersion>/manifest-linux-x64.json` and the relative `artifactPath`s from there.
Constraints if this is ever implemented:

- The manifest `sha256` values must match the served files; `artifactPath` must stay relative
  (absolute paths, `.` and `..` are rejected).
- ZCode's own closed-source components (`server-bundle`, `glm`) must be proxied/redirected to the
  vendor CDN rather than republished.
- A mirror must be published for every desktop version that is in use, otherwise the desktop falls
  back to its default CDN and the patch is reverted. This is the "patch kit" route, but automated.
- There is no settings-file switch; it is an OS-level environment variable for the desktop process.

Not implemented in this repository. `apply.sh` deliberately works without any desktop-side change.

## 6. Replacement details

| Component | Upstream | Built how | Verified |
| --- | --- | --- | --- |
| `node` | Node.js 22.16.0 **glibc-217** build | downloaded from unofficial-builds.nodejs.org, sha256 checked against `SHASUMS256.txt` | runs on glibc 2.17; max symbols `GLIBC_2.17`, `GLIBCXX_3.4.19`; `node zcode-server.cjs --version` → `3.14.3` |
| `pty.node` | npm `node-pty@1.2.0-beta.10` (exact version from the manifest) | `node-gyp rebuild` with devtoolset-11 g++, `-static-libstdc++ -static-libgcc` | max `GLIBC_2.14`, zero `GLIBCXX_*` refs; spawns a real ptmx (`/dev/pts/N`, `stty size` → rows/cols); exports `fork,open,resize,process` |
| `bfs` | upstream 4.1.1 | autotools, devtoolset-11 gcc | max `GLIBC_2.15` |
| `ugrep` | upstream 7.8.4 + PCRE2 10.44 (static, private prefix) | devtoolset-11 g++, `-static-libstdc++` | max `GLIBC_2.14`; `ldd` shows no libpcre2/libstdc++; banner reports `-P:pcre2` |

Build environment notes (EL7):

- node-gyp's bundled gyp needs Python ≥ 3.8; EL7 ships Python 3.6. Use `/opt/rh/rh-python38` when
  available, otherwise node-gyp@9 (its gyp still supports 3.6). `build/build-pty.sh` picks
  automatically.
- `pcre2-devel` and `libzstd` are absent on EL7 and installing RPMs is out of scope, hence the
  private static PCRE2 and `--without-zstd`.
- ugrep's SIMD support is runtime-dispatched; pass `UGREP_SIMD=--disable-avx2` for a conservative
  build.

## 7. Environment observations

- The ZCode desktop's own updater feed on the tested machine points at `http://localhost:8081`
  (`resources/app-update.yml`), i.e. a local, non-public feed; unrelated to the remote runtime, but
  worth knowing when reasoning about version bumps.
- The desktop keeps its cache in `%APPDATA%\ZCode\remote-assets-cache` (`ZCODE_REMOTE_ASSET_CACHE_DIR`
  overrides it) and writes deploy logs under `%APPDATA%\ZCode\..\.zcode\v2\logs\` — the
  `[deploy] [remote-assets]` lines are the fastest way to see why something was (re)uploaded.
