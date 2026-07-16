# Seafile mTLS - Nix flake

Seafile and SeaDrive desktop clients built with mutual TLS support, for Linux and macOS.

Sources: [seafile](https://github.com/shwewo/seafile), [seafile-client](https://github.com/shwewo/seafile-client), [seadrive-fuse](https://github.com/shwewo/seadrive-fuse), [seadrive-gui](https://github.com/shwewo/seadrive-gui).

Every push to `main` builds AppImages (x86_64 + aarch64 Linux) and a macOS pkg, and publishes them as a new [release](../../releases).

## Install

Prebuilt, no Nix needed - grab an asset from the [releases page](../../releases):

```
chmod +x seafile-*.AppImage && ./seafile-*.AppImage    # or seadrive-*.AppImage
sudo installer -pkg seafile-*.pkg -target /            # macOS
```

With Nix:

```
nix run github:shwewo/seafile-nix                      # run Seafile
nix build github:shwewo/seafile-nix#<output>           # build any output below
```

## Outputs

| Output | Platform | Description |
|---|---|---|
| `seafile-client` | all | Seafile Qt client (default) |
| `seafile-shared` | all | seaf-daemon only |
| `seafile-appdir` | Linux | Relocatable AppDir |
| `seafile-appimage` | Linux | Self-contained AppImage |
| `seadrive-gui` | Linux | SeaDrive Qt client |
| `seadrive-fuse` | Linux | seadrive FUSE daemon |
| `seadrive-appdir` | Linux | Relocatable AppDir |
| `seadrive-appimage` | Linux | Self-contained AppImage |
| `seafile-app` | macOS | Seafile.app bundle |
| `seafile-pkg` | macOS | pkg installer |

An AppDir is the app plus all runtime dependencies in one relocatable directory (unpacked form). An AppImage is that AppDir packed into a single executable (shippable form). The macOS app bundles the FinderSync extension from the official Seafile 9.0.19 DMG.

## Local dev

Point at sibling checkouts instead of the locked flake inputs:

```
~/seafile-nix/       # this flake
~/seafile-src/       # shwewo/seafile
~/seafile-client/    # shwewo/seafile-client
~/seadrive-fuse/     # shwewo/seadrive-fuse
~/seadrive-gui/      # shwewo/seadrive-gui

NIX_SEAFILE_LOCAL=1 nix build --impure   # --impure lets Nix read $PWD and the siblings
```
