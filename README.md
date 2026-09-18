# Seafile mTLS

Seafile and SeaDrive desktop clients, plus the Android app, built with mutual TLS support.

One monorepo, no forks: every component is pristine upstream ([haiwen](https://github.com/haiwen)) source fetched at a pinned tag, with a small mTLS patch from `nix/patches/` applied on top. Pins live in the `versions` block of `flake.nix`; patches apply via `pkgs.applyPatches` in `nix/default.nix`. See [Bumping a version](#bumping-a-version) below.

Every push to `main` first checks that every patch still applies against its pinned tag (`patches` job), then builds four artifacts in parallel and publishes them together as one new [release](../../releases):

| CI job | Runner | Artifact |
|---|---|---|
| `appimage` (matrix) | `ubuntu-latest` | `seafile-*-x86_64.AppImage`, `seadrive-*-x86_64.AppImage` |
| `appimage` (matrix) | `ubuntu-24.04-arm` | `seafile-*-aarch64.AppImage`, `seadrive-*-aarch64.AppImage` |
| `dmg` | `macos-latest` (Apple Silicon) | `seafile-*-aarch64.dmg` |
| `android` | `ubuntu-latest` | `seadroid-*.apk` (release-signed only — see [Android](#android)) |

Each row is a genuinely different build (different OS, different toolchain) — none of these are aliases or duplicates of each other, unlike the old `seafile-pkg` / `seafile-pkg-aarch64` naming this replaced. There is exactly one macOS artifact (a `.dmg`, Apple Silicon only — no Intel/x86_64-darwin build exists) and exactly one Android artifact (aarch64 Android, release-signed).

The release is always titled plain "Seafile" — no version in the title, just in the tag and the checksummed filenames. The Android build requires a real signing key to be configured (see [Android](#android)); without one, that job fails on purpose rather than quietly shipping an unsigned build.

## Install

Prebuilt, no Nix needed — grab an asset from the [releases page](../../releases):

```
chmod +x seafile-*.AppImage && ./seafile-*.AppImage    # or seadrive-*.AppImage
open seafile-*.dmg                                     # macOS — drag Seafile.app to Applications
adb install seadroid-*.apk                             # or copy the APK to the device
```

With Nix:

```
nix run github:shwewo/seafile-nix                      # run Seafile
nix build github:shwewo/seafile-nix#<output>           # build any output below
```

## On NixOS (no AppImage)

`seafile-client` and `seadrive-gui`/`seadrive-fuse` are store-native Nix packages in their own
right — the AppDir/AppImage outputs are just one way of shipping them (for non-NixOS Linux). On
NixOS, skip AppImage entirely and add this flake as an input to your system flake:

```nix
# flake.nix
{
  inputs.seafile-nix.url = "github:shwewo/seafile-nix";

  outputs = { self, nixpkgs, seafile-nix, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        {
          environment.systemPackages = [
            seafile-nix.packages.x86_64-linux.seafile-client   # Seafile (syncs specific libraries)
            seafile-nix.packages.x86_64-linux.seadrive-gui      # SeaDrive (mounts your whole library)
            seafile-nix.packages.x86_64-linux.seadrive-fuse
          ];
        }
      ];
    };
  };
}
```

Pick `seafile-client` or `seadrive-gui`+`seadrive-fuse` (or both — they don't conflict).
`seadrive-gui` needs `seadrive-fuse` alongside it; `seafile-client` needs nothing extra (it pulls
in `seafile-shared`/seaf-daemon itself). Rebuild with `nixos-rebuild switch --flake .#myhost`.
SeaDrive mounts via FUSE — if you hit a permission error mounting, make sure `programs.fuse` (or
just having `fuse3` in the closure, which it already is via this package) covers your setup; most
default NixOS configs need nothing extra here.

If you'd rather not add a flake input, `nix build github:shwewo/seafile-nix#seafile-client` and
`nix profile install` (or copy the store path into `environment.systemPackages` by hash) works
too, it's just less reproducible across rebuilds.

## Outputs

| Output | Platform | Description |
|---|---|---|
| `seafile-client` | all | Seafile Qt client (default) |
| `seafile-shared` | all | seaf-daemon only |
| `seafile-appdir` / `seafile-appimage` | Linux | Relocatable AppDir / self-contained AppImage |
| `seadrive-gui` | Linux | SeaDrive Qt client |
| `seadrive-fuse` | Linux | seadrive FUSE daemon |
| `seadrive-appdir` / `seadrive-appimage` | Linux | Relocatable AppDir / self-contained AppImage |
| `seafile-app` / `seafile-dmg` | macOS (aarch64) | .app bundle / .dmg disk image |
| `seadroid-src` | all | Patched Android source (see [Android](#android)) |
| `seadroid-debug-apk` | all | `nix run` → unsigned debug APK, no secrets (see [Android](#android)) |
| `patches-check` | all | Applies every patch, builds nothing else — what CI runs first |

The macOS app bundles the FinderSync extension from the official Seafile DMG.

## Android

Gradle resolves its own dependencies from Maven at build time, which needs network access the Nix sandbox doesn't allow — so unlike everything else here, the APK isn't a hermetic `nix build`. Nix provisions a reproducible JDK + Android SDK/NDK/CMake (pinned in `nix/android.nix`); Gradle then runs with normal network access, either via a one-liner (debug) or inside the dev shell by hand (release).

### Debug APK — no secrets needed

```
nix run github:shwewo/seafile-nix#seadroid-debug-apk
```

Fetches the patched source, builds `assembleDebug` with a throwaway self-signed keystore generated on the spot, and drops `seafile-debug-<version>.apk` in your current directory. This is what you want for testing a change locally — nothing to configure.

### Release APK — needs a real signing key, CI-only

There's deliberately no local one-liner for this: a release build must be signed with **your** real key, not a throwaway one, and that key can't live in this repo or its Nix store outputs (both are public). The `android` job in `.github/workflows/build.yml` requires four repo secrets — `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` — and **fails immediately, before checking anything out, if any of them are missing**. It does not fall back to an unsigned build; a broken/missing key blocks the release rather than silently shipping an unsigned APK under the Seafile name. Set those four secrets in the repo's GitHub settings before the Android job will pass.

Generate the keystore once, locally, and keep it out of the repo entirely (a password manager or a secrets vault, not a file in this checkout):

```
nix develop github:shwewo/seafile-nix#android -c keytool -genkeypair -v \
  -keystore release.keystore -alias seafile-release \
  -keyalg RSA -keysize 2048 -validity 10000
```

Then `base64 -w0 release.keystore` and paste that as `ANDROID_KEYSTORE_BASE64`, plus the three passwords/alias you were prompted for, as the other three secrets.

If you ever need to build a signed release locally instead of through CI (e.g. to test the signing config itself), the manual equivalent of what CI does is:

```
nix build github:shwewo/seafile-nix#seadroid-src -o seadroid-src
cp -rL seadroid-src seadroid && chmod -R u+w seadroid && cd seadroid
cp /path/to/release.keystore app/
cat > app/key.properties <<EOF
keyStore=release.keystore
keyStorePassword=...
keyAlias=seafile-release
keyAliasPassword=...
EOF
nix develop github:shwewo/seafile-nix#android -c ./gradlew assembleRelease
```

## Bumping a version

Edit the `rev` for the component in the `versions` block of `flake.nix`, then `nix build`. It will fail with the correct `hash` to paste in (or prefetch it yourself: `nix flake prefetch --json github:<owner>/<repo>/<tag>`).

If `nix/patches/<name>-mtls.patch` no longer applies cleanly against the new tag, `pkgs.applyPatches` (or, for Android, `./gradlew`) fails and points at the rejected hunk. Look at only that hunk — a few lines of context around the conflict — and reconcile it with the new upstream code; don't reread the whole file or the rest of the codebase to do this.

## Later: iOS

Not started. haiwen doesn't publish an open-source iOS client the same way, so this needs more scoping than a tag pin — flagging here so it isn't forgotten.
