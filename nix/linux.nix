# Linux packaging: relocatable AppDir and AppImage (no Nix at runtime).
{
  pkgs,
  lib,
  version,
  seafile-client,
  seafile-shared,
}:

let
  inherit (pkgs) runCommand qt6 bash coreutils patchelf findutils file binutils squashfsTools fetchurl;

  bundleScript = ../scripts/linux/bundle-appdir.sh;
  desktopFile = "${seafile-client}/share/applications/com.seafile.seafile-applet.desktop";
  iconFile = "${seafile-client}/share/pixmaps/seafile.png";

  # Packages whose /lib dirs must be visible to ldd while bundling.
  bundlePkgs =
    with qt6;
    [
      seafile-client
      seafile-shared
      qtbase
      qtsvg
      qtdeclarative
      qt5compat
    ]
    ++ (with pkgs; [
      jansson
      libsearpc
      libuuid
      openssl
      curl
      glib
      libevent
      sqlite
      libwebsockets
      libargon2
      util-linux
      libglvnd
      zlib
      libssh2
      krb5
      libidn2
      libpsl
      nghttp2
      nghttp3
      ngtcp2
      brotli
      zstd
      libunistring
      pcre2
      libffi
      libselinux
      keyutils
    ]);

  bundleLibPath = lib.makeLibraryPath bundlePkgs;

  appdir = runCommand "seafile-appdir-${version}"
    {
      nativeBuildInputs = [
        bash
        patchelf
        coreutils
        findutils
        file
        binutils
      ];
      buildInputs = bundlePkgs;
    }
    ''
      export LD_LIBRARY_PATH="${bundleLibPath}"
      export PATH="${lib.makeBinPath [ binutils patchelf ]}:$PATH"
      mkdir -p $out
      cp ${bundleScript} $TMPDIR/bundle-appdir.sh
      chmod +x $TMPDIR/bundle-appdir.sh
      ${bash}/bin/bash $TMPDIR/bundle-appdir.sh \
        $out \
        ${seafile-client} \
        ${seafile-shared} \
        ${qt6.qtbase} \
        ${version} \
        ${desktopFile} \
        ${iconFile}
    '';

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

  seafile-appimage = runCommand "seafile-${version}.AppImage"
    {
      nativeBuildInputs = [ squashfsTools coreutils ];
    }
    ''
      cp -r ${appdir} AppDir
      chmod +x AppDir/AppRun
      mksquashfs AppDir filesystem.squashfs -root-owned -noappend -comp zstd
      cat ${appimageRuntime} filesystem.squashfs > "$out"
      chmod +x "$out"
    '';

in
{
  inherit appdir seafile-appimage;
}