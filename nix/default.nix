# Build Seafile mTLS packages for the current platform.
{
  pkgs,
  lib,
  seafileSrc,
  seafileClientSrc,
  seadriveFuseSrc,
  seadriveGuiSrc,
}:

let
  sources = import ./lib.nix {
    inherit lib seafileSrc seafileClientSrc;
  };

  components = import ./components.nix {
    inherit pkgs lib;
    version = sources.version;
    seafileSrc = sources.seafileSrc;
    seafileClientSrc = sources.seafileClientSrc;
  };

  darwin = import ./darwin.nix {
    inherit pkgs lib;
    version = sources.version;
    seafileClientSrc = sources.seafileClientSrc;
    seafile-client = components.seafile-client-app;
    seafile-shared = components.seafile-shared;
  };

  linux = import ./linux.nix {
    inherit pkgs lib seadriveFuseSrc seadriveGuiSrc;
    version = sources.version;
    seadriveVersion = sources.seadriveVersion;
    seafile-client = components.seafile-client;
    seafile-shared = components.seafile-shared;
  };

in
{
  # nix build .#seafile-shared      → seaf-daemon only (all platforms)
  # nix build .#seafile-client      → Seafile Qt client, default output (all platforms)
  inherit (components) seafile-shared seafile-client;
}
// lib.optionalAttrs pkgs.stdenv.isLinux {
  # Linux AppDir / AppImage outputs and SeaDrive derivations — see nix/linux.nix
  seafile-appdir = linux.appdir;
  seafile-appimage = linux.seafile-appimage;
  inherit (linux) seadrive-fuse seadrive-gui seadrive-appdir seadrive-appimage;
}
// lib.optionalAttrs pkgs.stdenv.isDarwin {
  # nix build .#seafile-app         → Seafile.app bundle
  # nix build .#seafile-pkg         → single-arch macOS installer
  # nix build .#seafile-pkg-universal → universal (arm64+x86_64) macOS installer
  inherit (darwin) seafile-app seafile-pkg mkUniversalPkg;
}
