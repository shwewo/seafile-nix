# Build Seafile mTLS packages for the current platform.
{
  pkgs,
  lib,
  seafileSrc,
  seafileClientSrc,
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
    inherit pkgs lib;
    version = sources.version;
    seafile-client = components.seafile-client;
    seafile-shared = components.seafile-shared;
  };

in
{
  inherit (components) seafile-shared seafile-client;
}
// lib.optionalAttrs pkgs.stdenv.isLinux {
  seafile-appdir = linux.appdir;
  seafile-appimage = linux.seafile-appimage;
}
// lib.optionalAttrs pkgs.stdenv.isDarwin {
  inherit (darwin) seafile-app seafile-pkg mkUniversalPkg;
}