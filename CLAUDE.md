# seafile-nix

Builds Seafile + SeaDrive (Linux, macOS) and the Seafile Android client, with mutual TLS
(client certificate) support added on top of upstream. This repo is the only place the mTLS
support lives.

## Model: pristine upstream + one patch per component

- Sources are upstream `haiwen/*` repos, fetched with `fetchFromGitHub` at a **tag** pinned in
  the `versions` block of `flake.nix` (the only place versions live).
- Each component gets exactly one patch, `nix/patches/<name>-mtls.patch`, applied with
  `pkgs.applyPatches` (`nix/default.nix`). It contains **only** the mTLS change.
- Version strings come from the pinned tag (`versionOf` in `nix/default.nix`).
- The old `shwewo/*` forks are retired. Never add them back as inputs.

## Layout

```
flake.nix                 # nixpkgs input, `versions` pin table, outputs
nix/default.nix           # fetch + patch each component; wires everything together
nix/components.nix        # seafile-shared (seaf-daemon) + seafile-client (Qt)
nix/linux.nix             # AppDir/AppImage for Seafile + SeaDrive
nix/darwin.nix            # Seafile.app + aarch64 .pkg
nix/android.nix           # seadroid dev shell (JDK/SDK/NDK); not a sandboxed build
nix/patches/*-mtls.patch  # one per component, mTLS-only
nix/patches/qtbase-macos27-tray-crash.patch  # not mTLS: Qt 6.12 backport for the macOS
                          # bundle's libqcocoa only; drop once nixpkgs has Qt >= 6.12
scripts/darwin/bundle.sh  # makes Seafile.app relocatable (no /nix/store refs)
.github/workflows/build.yml  # builds everything, one release per push to main
```

## Pins that aren't "latest"

- `seafile` and `seafile-client` are both on **v9.0.20**, on purpose. Client v9.0.21 needs core
  v9.0.21, and core v9.0.21 rewrote `daemon/notif-mgr.c`, which the mTLS patch touches. Bump
  them together, and reconcile the patch by hand.
- `seadrive-gui` is on **v3.0.22**, the only version its patch was verified against.

## Android

Gradle needs network access, so it runs in `nix develop .#android`, not in `nix build`.
- If a `seadroid` bump makes AGP ask for a different NDK or CMake version, change it in
  `nix/android.nix`.
- `app/build.gradle` always loads `app/key.properties`, even for debug builds. CI writes one
  from repo secrets (release build), or generates a throwaway key (debug build).

## Bumping a version

1. Change `rev` in `versions` to the new **tag**, then build to get the new `hash`.
2. If the patch fails, reconcile only the rejected hunk against the new upstream code. Get the
   C/C++ TLS changes reviewed by someone else.
3. Regenerate the patch as `git diff <tag>..<result>`, limited to the same files as before.

## Don't

- Pin `rev` to a branch.
- Re-add the `shwewo/*` forks.
- Put anything other than the mTLS change in an `*-mtls.patch` (no formatting changes, no
  unrelated fixes).
