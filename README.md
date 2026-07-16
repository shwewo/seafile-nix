# Seafile mTLS — Nix flake

[Seafile](https://github.com/shwewo/seafile-client) and [SeaDrive](https://github.com/shwewo/seadrive-gui) desktop clients built with mutual TLS support, for Linux and macOS.

Sources: [seafile](https://github.com/shwewo/seafile), [seafile-client](https://github.com/shwewo/seafile-client), [seadrive-fuse](https://github.com/shwewo/seadrive-fuse), [seadrive-gui](https://github.com/shwewo/seadrive-gui).

Every push to `main` builds AppImages (x86_64 + aarch64 Linux) and a macOS `.pkg`, and publishes them as a new [release](../../releases).

## Prebuilt (no Nix)

Grab an AppImage or `.pkg` from the [releases page](../../releases):

```bash
chmod +x seafile-*.AppImage && ./seafile-*.AppImage   # or seadrive-*.AppImage
sudo installer -pkg seafile-*.pkg -target /           # macOS
```

## With Nix

```bash
nix run github:shwewo/seafile-nix                      # run Seafile
nix build github:shwewo/seafile-nix#<output>           # build any output below
```

Use `.#<output>` from a local clone.

## Outputs

| Output | Platform | Description |
|---|---|---|
| `seafile-client` | all | Seafile Qt client (default) |
| `seafile-shared` | all | `seaf-daemon` only |
| `seafile-appdir` | Linux | Relocatable [AppDir](#what-is-an-appdir) |
| `seafile-appimage` | Linux | Self-contained AppImage |
| `seadrive-gui` | Linux | SeaDrive Qt client |
| `seadrive-fuse` | Linux | `seadrive` FUSE daemon |
| `seadrive-appdir` | Linux | Relocatable AppDir |
| `seadrive-appimage` | Linux | Self-contained AppImage |
| `seafile-app` | macOS | `Seafile.app` bundle |
| `seafile-pkg` | macOS | `.pkg` installer |

The macOS `.app` bundles the FinderSync extension extracted from the official Seafile `9.0.19` DMG:

```bash
nix build .#seafile-app && open result/Applications/Seafile.app
```

## What is an AppDir?

An **AppDir** is a relocatable directory holding the app plus every runtime dependency (libraries, plugins, resources) laid out per the AppImage spec, with an `AppRun` launcher at its root. It runs from anywhere without installation. An **AppImage** is just that AppDir packed into a single self-contained executable — so `*-appdir` is the unpacked form (handy for inspection/debugging) and `*-appimage` is the shippable one-file build.

## Local dev

Point at sibling checkouts instead of the locked flake inputs:

```
~/seafile-nix/       # this flake
~/seafile-src/       # shwewo/seafile
~/seafile-client/    # shwewo/seafile-client
```

```bash
NIX_SEAFILE_LOCAL=1 nix build --impure   # --impure lets Nix read $PWD / ../seafile-*
```

SeaDrive always uses the locked flake inputs (no local override).
