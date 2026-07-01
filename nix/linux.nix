# Linux packaging: relocatable AppDir and AppImage for Seafile and SeaDrive.
{
  pkgs,
  lib,
  version,
  seadriveVersion,
  seafile-client,
  seafile-shared,
  seadriveFuseSrc,
  seadriveGuiSrc,
}:

let
  inherit (pkgs) runCommand qt6 bash coreutils patchelf findutils file binutils squashfsTools fetchurl;

  # ── SeaDrive derivations ─────────────────────────────────────────────────────

  seadrive-fuse = pkgs.seadrive-fuse.overrideAttrs (_old: {
    version = seadriveVersion;
    src = seadriveFuseSrc;
  });

  seadrive-gui = (pkgs.seadrive-gui.override {
    inherit seadrive-fuse seafile-shared;
  }).overrideAttrs (_old: {
    version = seadriveVersion;
    src = seadriveGuiSrc;
  });

  # ── Shared helpers ───────────────────────────────────────────────────────────

  dynamicLinker =
    if pkgs.stdenv.isx86_64 then "/lib64/ld-linux-x86-64.so.2"
    else if pkgs.stdenv.isAarch64 then "/lib/ld-linux-aarch64.so.1"
    else throw "unsupported Linux architecture for AppDir";

  appimageRuntime =
    let
      runtimes = {
        "x86_64-linux" = fetchurl {
          url = "https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64";
          hash = "sha256-HMSbzx4szVk8N5rbF8n4WjbWGQiCllBN6VsdBiFa678=";
        };
        "aarch64-linux" = fetchurl {
          url = "https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-aarch64";
          hash = "sha256-fV13K3wy8MhMrwpFKjBypXCQJ9fqxYVv64mnp6iIE3I=";
        };
      };
    in
    runtimes.${pkgs.stdenv.system} or (throw "no AppImage runtime for ${pkgs.stdenv.system}");

  mkAppImage = name: appdir:
    runCommand "${name}.AppImage"
      { nativeBuildInputs = [ squashfsTools coreutils ]; }
      ''
        cp -r ${appdir} AppDir
        chmod +x AppDir/AppRun
        mksquashfs AppDir filesystem.squashfs -noappend -comp gzip
        cat ${appimageRuntime} filesystem.squashfs > "$out"
        chmod +x "$out"
      '';

  # Libraries needed by both Seafile and SeaDrive bundles.
  commonPkgs = with qt6; [
    qtbase qtsvg qtdeclarative qt5compat
  ] ++ (with pkgs; [
    jansson libsearpc libuuid openssl curl glib libevent sqlite libwebsockets
    libargon2 util-linux libglvnd zlib libssh2 krb5 libidn2 libpsl
    nghttp2 nghttp3 ngtcp2 brotli zstd libunistring pcre2 libffi
    libselinux keyutils vulkan-loader
  ]);

  # ── Seafile AppDir / AppImage ────────────────────────────────────────────────

  seafileBundlePkgs = [ seafile-client seafile-shared ] ++ commonPkgs;

  seafile-appdir = runCommand "seafile-appdir-${version}"
    {
      nativeBuildInputs = [ bash patchelf coreutils findutils file binutils ];
      buildInputs = seafileBundlePkgs;
    }
    ''
      export LD_LIBRARY_PATH="${lib.makeLibraryPath seafileBundlePkgs}"
      export PATH="${lib.makeBinPath [ binutils patchelf ]}:$PATH"
      mkdir -p $out
      cp ${../scripts/linux/bundle-appdir.sh} $TMPDIR/bundle.sh
      chmod +x $TMPDIR/bundle.sh
      ${bash}/bin/bash $TMPDIR/bundle.sh \
        $out \
        ${seafile-client} \
        ${seafile-shared} \
        ${qt6.qtbase} \
        ${version} \
        ${seafile-client}/share/applications/com.seafile.seafile-applet.desktop \
        ${seafile-client}/share/pixmaps/seafile.png \
        ${dynamicLinker}
    '';

  # ── SeaDrive AppDir / AppImage ───────────────────────────────────────────────

  seadriveBundlePkgs = with qt6; [
    seadrive-gui seadrive-fuse
    qtlocation qtpositioning qtwebchannel qtwebsockets qtwebengine
  ] ++ commonPkgs ++ [ pkgs.fuse ];

  seadrive-appdir = runCommand "seadrive-appdir-${seadriveVersion}"
    {
      nativeBuildInputs = [ bash patchelf coreutils findutils file binutils ];
      buildInputs = seadriveBundlePkgs;
    }
    ''
      export LD_LIBRARY_PATH="${lib.makeLibraryPath seadriveBundlePkgs}"
      export PATH="${lib.makeBinPath [ binutils patchelf ]}:$PATH"
      mkdir -p $out
      cp ${../scripts/linux/bundle-seadrive-appdir.sh} $TMPDIR/bundle.sh
      chmod +x $TMPDIR/bundle.sh
      ${bash}/bin/bash $TMPDIR/bundle.sh \
        $out \
        ${seadrive-gui} \
        ${seadrive-fuse} \
        ${qt6.qtbase} \
        ${seadriveVersion} \
        ${seadrive-gui}/share/applications/seadrive.desktop \
        ${seadrive-gui}/share/pixmaps/seadrive.png \
        ${dynamicLinker}
    '';

in
{
  # nix build .#seadrive-fuse       → mTLS-patched seadrive FUSE daemon (store-native)
  # nix build .#seadrive-gui        → SeaDrive Qt client linked against the above (store-native)
  inherit seadrive-fuse seadrive-gui;

  # nix build .#seafile-appdir      → relocatable AppDir tree, run with ./result/AppRun
  appdir = seafile-appdir;

  # nix build .#seafile-appimage    → self-contained Seafile AppImage
  seafile-appimage = mkAppImage "seafile-${version}" seafile-appdir;

  # nix build .#seadrive-appdir     → relocatable SeaDrive AppDir tree, run with ./result/AppRun
  seadrive-appdir = seadrive-appdir;

  # nix build .#seadrive-appimage   → self-contained SeaDrive AppImage (GUI + FUSE daemon)
  seadrive-appimage = mkAppImage "seadrive-${seadriveVersion}" seadrive-appdir;
}
