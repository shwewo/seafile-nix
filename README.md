# Seafile mTLS — Nix flake

Sources: [shwewo/seafile](https://github.com/shwewo/seafile), [shwewo/seafile-client](https://github.com/shwewo/seafile-client) (flake inputs, pinned in `flake.lock`).

## Run (store-native)

Same on **Linux and macOS** — default output (`nix build` → `seafile-client`):

```bash
nix build github:shwewo/seafile-nix
./result/bin/seafile-applet
```

From a clone:

```bash
cd seafile-nix
nix build
./result/bin/seafile-applet
```

```bash
nix profile install .#seafile-client
nix shell .#seafile-client
```

Daemon only: `nix build .#seafile-shared`

## Local dev

Check out three sibling directories:

```
~/seafile-nix/       # this flake
~/seafile-src/       # shwewo/seafile
~/seafile-client/    # shwewo/seafile-client
```

Build from the flake dir with local trees instead of `flake.lock` inputs:

```bash
cd ~/seafile-nix
NIX_SEAFILE_LOCAL=1 nix build --impure
./result/bin/seafile-applet
```

`--impure` is required so Nix can read `$PWD` and resolve `../seafile-src` / `../seafile-client`.

Alternative (explicit paths, no env var):

```bash
nix build --impure \
  --override-input seafile path:../seafile-src \
  --override-input seafile-client path:../seafile-client
```

Works for any output, e.g. `NIX_SEAFILE_LOCAL=1 nix build .#seafile-appimage --impure`.

## Distributables (no Nix at runtime)

| Platform       | Output             | Build                                           | Run                                                    |
|----------------|--------------------|-------------------------------------------------|--------------------------------------------------------|
| Linux x86_64   | AppImage           | `nix build .#seafile-appimage`                  | `./result`                                             |
| Linux          | AppDir             | `nix build .#seafile-appdir`                    | `./result/AppRun`                                      |
| macOS          | `.app`             | `nix build .#seafile-app`                       | `open result/Applications/Seafile.app`                 |
| macOS          | `.pkg`             | `nix build .#seafile-pkg`                       | `sudo installer -pkg result -target /`                 |
| macOS          | universal `.pkg`   | `nix build .#seafile-pkg-universal`             | same as `.pkg`                                         |

AppImage uses a hardcoded x86_64 runtime — build and run on x86_64 Linux only.

The macOS `.app` bundle includes the FinderSync extension extracted from the official Seafile DMG (`seafile-client-9.0.19.dmg`).

Universal macOS builds need Rosetta and `extra-platforms = aarch64-darwin x86_64-darwin` in Nix config.