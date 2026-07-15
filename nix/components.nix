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
        # The old cctools ld64 (1010.6) crashes (SIGTRAP) linking the large Qt
        # applet on aarch64-darwin under nixpkgs 26.11; use LLVM's lld instead.
        nativeBuildInputs =
          (old.nativeBuildInputs or [ ])
          ++ lib.optional isDarwin pkgs.lld;
        cmakeFlags =
          (old.cmakeFlags or [ ])
          ++ [
            "-DBUILD_CLIENT_SSO_SUPPORT=ON"
            "-DBUILD_SHIBBOLETH_SUPPORT=OFF"
          ]
          ++ lib.optionals isDarwin [
            "-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld"
            "-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld"
          ];
        postPatch =
          (old.postPatch or "")
          # nixpkgs 26.11 ships Darwin deps built for macOS 13/14; the client
          # hardcodes a deployment target of 11. Bump it to match so lld doesn't
          # warn about linking newer dylibs into an older-targeted binary.
          + lib.optionalString isDarwin ''
            substituteInPlace CMakeLists.txt \
              --replace-fail 'SET(CMAKE_OSX_DEPLOYMENT_TARGET "11")' 'SET(CMAKE_OSX_DEPLOYMENT_TARGET "14")'
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