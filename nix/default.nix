# Build Seafile mTLS packages for the current platform.
#
# Each component is pristine upstream source, fetched at the tag pinned in
# ../flake.nix, with nix/patches/<name>-mtls.patch applied on top via
# pkgs.applyPatches. There is no fork checkout involved — upstream plus a
# patch is the whole story. See ../flake.nix for how to bump a version.
{
  pkgs,
  lib,
  versions,
}:

let
  # "v9.0.20" -> "9.0.20-mtls"
  versionOf = name: lib.removePrefix "v" versions.${name}.rev + "-mtls";

  mkSrc =
    name:
    pkgs.applyPatches {
      name = "${name}-mtls-src";
      version = versionOf name;
      src = pkgs.fetchFromGitHub versions.${name};
      patches = [ ./patches/${name}-mtls.patch ];
    };

  seafileSrc = mkSrc "seafile";
  seafileClientSrc = mkSrc "seafile-client";
  seadriveFuseSrc = mkSrc "seadrive-fuse";
  seadriveGuiSrc = mkSrc "seadrive-gui";
  seadroidSrc = mkSrc "seadroid";

  # seaf-daemon and the Qt client are packaged under one version label even
  # though their upstream tags can drift slightly (see versionOf); this
  # matches how upstream releases them (in lockstep) closely enough for a
  # package version string.
  version = versionOf "seafile-client";
  seadriveVersion = versionOf "seadrive-gui";

  components = import ./components.nix {
    inherit pkgs lib version;
    seafileSrc = seafileSrc;
    seafileClientSrc = seafileClientSrc;
  };

  darwin = import ./darwin.nix {
    inherit pkgs lib version;
    seafileClientSrc = seafileClientSrc;
    seafile-client = components.seafile-client-app;
    seafile-shared = components.seafile-shared;
  };

  linux = import ./linux.nix {
    inherit pkgs lib version seadriveVersion;
    seadriveFuseSrc = seadriveFuseSrc;
    seadriveGuiSrc = seadriveGuiSrc;
    seafile-client = components.seafile-client;
    seafile-shared = components.seafile-shared;
  };

  android = import ./android.nix {
    inherit pkgs lib;
    seadroidSrc = seadroidSrc;
  };

  # Patched sources only — fetch + patch, no compiler involved. Cheap and
  # fast, so CI builds these before anything else: if a patch has bitrotted
  # against its pinned tag, this fails in seconds instead of minutes into a
  # Qt/Gradle build. `patches-check` builds all of them in one command.
  patchedSources = {
    seafile-src = seafileSrc;
    seafile-client-src = seafileClientSrc;
    seadrive-fuse-src = seadriveFuseSrc;
    seadrive-gui-src = seadriveGuiSrc;
    seadroid-src = seadroidSrc;
  };

  packages =
    {
      # nix build .#seafile-shared      → seaf-daemon only (all platforms)
      # nix build .#seafile-client      → Seafile Qt client, default output (all platforms)
      inherit (components) seafile-shared seafile-client;

      # nix build .#patches-check       → applies every patch, builds nothing else (all platforms)
      # nix run   .#seadroid-debug-apk  → builds + drops an unsigned debug APK in $PWD (needs network at run time, see nix/android.nix)
      patches-check = pkgs.linkFarm "patches-check" patchedSources;
      seadroid-debug-apk = android.debugApk;
    }
    // patchedSources
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      # Linux AppDir / AppImage outputs and SeaDrive derivations — see nix/linux.nix
      seafile-appdir = linux.appdir;
      seafile-appimage = linux.seafile-appimage;
      inherit (linux) seadrive-fuse seadrive-gui seadrive-appdir seadrive-appimage;
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
      # nix build .#seafile-app → Seafile.app bundle
      # nix build .#seafile-pkg → aarch64 macOS installer
      inherit (darwin) seafile-app seafile-pkg;
    };

in
{
  inherit packages;
  # nix develop .#android → JDK + Android SDK for building seadroid, see nix/android.nix
  devShells.android = android.devShell;
}
