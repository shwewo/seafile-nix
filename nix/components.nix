# Core derivations: patched seaf-daemon (seafile-shared) and Qt client.
{
  pkgs,
  lib,
  version,
  seafileSrc,
  seafileClientSrc,
}:

let
  isDarwin = pkgs.stdenv.isDarwin;

  seafile-shared = pkgs.seafile-shared.overrideAttrs (old: {
    inherit version;
    src = seafileSrc;
    postPatch =
      (old.postPatch or "")
      + lib.optionalString isDarwin ''
        substituteInPlace lib/Makefile.am \
          --replace-fail "sed -i ${"''"} -e" "sed -i -e"
      '';
    meta =
      old.meta
      // lib.optionalAttrs isDarwin {
        platforms = old.meta.platforms ++ lib.platforms.darwin;
      };
  });

  # bundleApp: true  → Resources/seaf-daemon path (for Seafile.app packaging)
  # bundleApp: false → seaf-daemon on PATH via nix wrapper (store-native, like Linux)
  mkSeafileClient =
    bundleApp:
    (pkgs.seafile-client.override {
      inherit seafile-shared;
      withShibboleth = false;
    }).overrideAttrs
      (old: {
        inherit version;
        src = seafileClientSrc;
        cmakeFlags =
          (old.cmakeFlags or [ ])
          ++ [
            "-DBUILD_CLIENT_SSO_SUPPORT=ON"
            "-DBUILD_SHIBBOLETH_SUPPORT=OFF"
          ];
        postPatch =
          (old.postPatch or "")
          + lib.optionalString isDarwin ''
            substituteInPlace CMakeLists.txt \
              --replace 'ADD_DEFINITIONS(-DHAVE_FINDER_SYNC_SUPPORT)' "" || true
          ''
          + lib.optionalString (isDarwin && bundleApp) ''
            substituteInPlace src/utils/utils.h \
              --replace-fail '#if defined(XCODE_APP)' '#if 1'
          '';
        inherit (old) patches;
        meta =
          old.meta
          // lib.optionalAttrs isDarwin {
            platforms = old.meta.platforms ++ lib.platforms.darwin;
          };
      });

  # Store-native client: seaf-daemon comes from seafile-shared via wrapped PATH.
  seafile-client = mkSeafileClient false;

  # Only used when assembling a relocatable .app bundle.
  seafile-client-app = mkSeafileClient true;

in
{
  inherit seafile-shared seafile-client seafile-client-app;
}