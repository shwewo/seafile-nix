# Build all Seafile/SeaDrive mTLS packages for the current platform.
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
    inherit lib seafileSrc seafileClientSrc seadriveFuseSrc seadriveGuiSrc;
  };

  components = import ./components.nix {
    inherit pkgs lib;
    version = sources.version;
    seafileSrc = sources.seafileSrc;
    seafileClientSrc = sources.seafileClientSrc;
  };

  seadrive = import ./seadrive.nix {
    inherit pkgs lib;
    version = sources.seadriveVersion;
    seafile-shared = components.seafile-shared;
    seadriveFuseSrc = sources.seadriveFuseSrc;
    seadriveGuiSrc = sources.seadriveGuiSrc;
  };

  darwin =
    import ./darwin.nix {
      inherit pkgs lib;
      version = sources.version;
      seafileClientSrc = sources.seafileClientSrc;
      seafile-client = components.seafile-client-app;
      seafile-shared = components.seafile-shared;
    };

  linux =
    import ./linux.nix {
      inherit pkgs lib;
      version = sources.version;
      seafile-client = components.seafile-client;
      seafile-shared = components.seafile-shared;
    };

in
{
  inherit (components) seafile-shared seafile-client;
  inherit (seadrive) seadrive-fuse seadrive-gui;
}
// lib.optionalAttrs pkgs.stdenv.isLinux {
  seafile-appdir = linux.appdir;
  seafile-appimage = linux.seafile-appimage;
}
// lib.optionalAttrs pkgs.stdenv.isDarwin {
  seafile-app    = darwin.seafile-app;
  seafile-pkg    = darwin.seafile-pkg;
  mkUniversalPkg = darwin.pkgUniversal;
  seadrive-app   = seadrive.seadrive-app;
  seadrive-pkg   = seadrive.seadrive-pkg;
  mkUniversalSeadrivePkg = seadrive.pkgUniversal;
}