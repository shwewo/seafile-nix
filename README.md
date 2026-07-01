# Seafile mTLS — Nix flake

Builds [Seafile](https://github.com/shwewo/seafile-client) and [SeaDrive](https://github.com/shwewo/seadrive-gui) desktop clients with mutual TLS support.

Sources: [shwewo/seafile](https://github.com/shwewo/seafile), [shwewo/seafile-client](https://github.com/shwewo/seafile-client), [shwewo/seadrive-fuse](https://github.com/shwewo/seadrive-fuse), [shwewo/seadrive-gui](https://github.com/shwewo/seadrive-gui).

CI builds AppImages for x86_64 and aarch64 Linux, plus a universal macOS `.pkg`, on every push to `main`. Artifacts are published to the [releases page](../../releases).

## Packages

| Output | Description |
|---|---|
| `seafile-client` | Seafile Qt client (store-native, default) |
| `seafile-shared` | seaf-daemon only |
| `seafile-appdir` | Relocatable AppDir (Linux) |
| `seafile-appimage` | Self-contained AppImage (Linux) |
| `seadrive-gui` | SeaDrive Qt client (store-native, Linux) |
| `seadrive-fuse` | seadrive FUSE daemon with mTLS (store-native, Linux) |
| `seadrive-appdir` | Relocatable AppDir (Linux) |
| `seadrive-appimage` | Self-contained AppImage (Linux) |
| `seafile-app` | Seafile.app bundle (macOS) |
| `seafile-pkg` | Single-arch macOS installer |
| `seafile-pkg-universal` | Universal (arm64+x86_64) macOS installer |

## Run without installing (store-native)

**Seafile:**
```bash
nix run github:shwewo/seafile-nix
# or
nix build github:shwewo/seafile-nix && ./result/bin/seafile-applet
```

**SeaDrive** (Linux only):
```bash
nix build github:shwewo/seafile-nix#seadrive-gui && ./result/bin/seadrive-gui
```

From a local clone, substitute `github:shwewo/seafile-nix` with `.`.

## AppImages (no Nix required)

Download from the [releases page](../../releases), then:

```bash
chmod +x seafile-*.AppImage && ./seafile-*.AppImage
chmod +x seadrive-*.AppImage && ./seadrive-*.AppImage
```

Or build locally:

```bash
nix build .#seafile-appimage   # → ./result
nix build .#seadrive-appimage  # → ./result
```

## macOS

```bash
# .app (open directly)
nix build .#seafile-app
open result/Applications/Seafile.app

# universal .pkg (installs to /Applications)
nix build .#seafile-pkg-universal
sudo installer -pkg result -target /
```

The `.app` bundle includes the FinderSync extension extracted from the official Seafile `9.0.19` DMG.

Universal builds need Rosetta and `extra-platforms = aarch64-darwin x86_64-darwin` in `nix.conf`.

## Local dev

Check out sibling directories:

```
~/seafile-nix/       # this flake
~/seafile-src/       # shwewo/seafile
~/seafile-client/    # shwewo/seafile-client
```

Build with local trees instead of locked flake inputs:

```bash
cd ~/seafile-nix
NIX_SEAFILE_LOCAL=1 nix build --impure
```

`--impure` is needed so Nix can read `$PWD` and resolve `../seafile-src` / `../seafile-client`.

SeaDrive always uses the locked flake inputs (no local override path).
