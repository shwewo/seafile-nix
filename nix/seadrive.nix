# SeaDrive derivations: patched seadrive-fuse (daemon) and seadrive-gui (Qt).
# Linux: overrides nixpkgs packages (which are Linux-only upstream).
# macOS: written from scratch — nixpkgs marks both as linux-only.
{
  pkgs,
  lib,
  version,
  seafile-shared,
  seadriveFuseSrc,
  seadriveGuiSrc,
}:

let
  inherit (pkgs) stdenv runCommand;

  seadrive-fuse =
    if stdenv.isLinux then
      pkgs.seadrive-fuse.overrideAttrs (_old: {
        version = version;
        src = seadriveFuseSrc;
        buildInputs = [
          pkgs.libargon2
          pkgs.libuuid
          pkgs.sqlite
          pkgs.libsearpc
          pkgs.libevent
          pkgs.curl
          pkgs.openssl
          pkgs.jansson
        ];
      })
    else
      stdenv.mkDerivation {
        pname = "seadrive-fuse";
        version = version;
        src = seadriveFuseSrc;

        nativeBuildInputs = [
          pkgs.autoreconfHook
          pkgs.pkg-config
          pkgs.python3
          pkgs.vala
          pkgs.libwebsockets
          pkgs.macfuse-stubs
        ];

        buildInputs = [
          pkgs.libargon2
          pkgs.sqlite
          pkgs.libsearpc
          pkgs.libevent
          pkgs.curl
          pkgs.openssl
          pkgs.jansson
        ];

        meta.mainProgram = "seadrive";
      };

  seadrive-gui =
    if stdenv.isLinux then
      pkgs.seadrive-gui.overrideAttrs (_old: {
        version = version;
        src = seadriveGuiSrc;
        postPatch = ''
          substituteInPlace CMakeLists.txt \
            --replace-fail 'CMAKE_MINIMUM_REQUIRED(VERSION 2.8.9)' 'CMAKE_MINIMUM_REQUIRED(VERSION 3.10)' \
            --replace-fail 'TARGET_LINK_LIBRARIES(seadrive-gui PRIVATE Qt6::DBus)' 'TARGET_LINK_LIBRARIES(seadrive-gui Qt6::DBus)'
        '';
        buildInputs = [
          pkgs.qt6.qt5compat
          pkgs.qt6.qtwebengine
          seafile-shared
          pkgs.jansson
          pkgs.libsearpc
          pkgs.libuuid
          seadrive-fuse
        ];
        qtWrapperArgs = [
          "--suffix PATH : ${lib.makeBinPath [ seadrive-fuse ]}"
        ];
      })
    else
      stdenv.mkDerivation {
        pname = "seadrive-gui";
        version = version;
        src = seadriveGuiSrc;

        nativeBuildInputs = [
          pkgs.pkg-config
          pkgs.cmake
          pkgs.qt6.qttools
        ];

        buildInputs = [
          pkgs.qt6.qtbase
          pkgs.qt6.qt5compat
          seafile-shared
          pkgs.jansson
          pkgs.libsearpc
          seadrive-fuse
        ];

        cmakeFlags = [
          "-DCMAKE_BUILD_TYPE=Release"
          "-DSEADRIVE_USE_FUSE=OFF"
        ];

        # Qt's moc has its own preprocessor and does NOT inherit compiler
        # platform macros like __APPLE__. Without Q_OS_MAC, conditional
        # slots (e.g. connectDaemon) are excluded from the metaclass and
        # Qt emits "No such slot" at runtime.
        # Qt 6 cmake ignores CMAKE_AUTOMOC_MOC_OPTIONS and uses the moc
        # found via QT_OPTIONAL_TOOLS_PATH (absolute Nix store path), so
        # PATH-based wrapping is also bypassed. The only reliable hook is
        # QT_MOC_EXECUTABLE — we create a wrapper script and tell cmake to
        # use it by appending to cmakeFlagsArray in preConfigure.
        preConfigure = ''
          mkdir -p $TMPDIR/moc-wrapper
          printf '#!/bin/sh\nexec %s/libexec/moc -DQ_OS_MAC "$@"\n' \
            ${pkgs.qt6.qtbase} > $TMPDIR/moc-wrapper/moc
          chmod +x $TMPDIR/moc-wrapper/moc
          cmakeFlagsArray+=("-DQT_MOC_EXECUTABLE=$TMPDIR/moc-wrapper/moc")
        '';

        # wrapQtAppsHook segfaults on macOS 26 beta; Qt dylib rpaths are
        # set at link time via @rpath so this is safe to skip.
        dontWrapQtApps = true;

        meta.mainProgram = "seadrive-gui";
      };

in
if stdenv.isLinux then
  { inherit seadrive-fuse seadrive-gui; }
else
  let
    inherit (pkgs) qt6 macdylibbundler cctools coreutils findutils xar bomutils cpio gzip fetchurl;

    bundleScript = ../scripts/darwin/bundle-seadrive.sh;
    infoPlist    = "${seadriveGuiSrc}/Info.plist";
    icnsDir      = seadriveGuiSrc;

    qtPluginDirs = lib.concatStringsSep ":" [
      "${qt6.qtbase}/lib/qt-6/plugins"
      "${qt6.qtsvg}/lib/qt-6/plugins"
      "${qt6.qtdeclarative}/lib/qt-6/plugins"
      "${qt6.qt5compat}/lib/qt-6/plugins"
    ];

    # Extract File Provider extension from the official SeaDrive binary pkg.
    # The extension is proprietary and not in our source tree.
    officialPkg = fetchurl {
      url    = "https://s3.eu-central-1.amazonaws.com/download.seadrive.org/seadrive-3.0.2.pkg";
      sha256 = "57a8467040dc66f94e6622c54a2a38f81c8d2a9f1a832e789b1f3242d6738908";
    };

    fproviderAppex = runCommand "seadrive-fprovider-appex"
      { nativeBuildInputs = [ xar cpio gzip coreutils findutils ]; }
      ''
        work=$(mktemp -d)
        cd "$work"
        xar -xf ${officialPkg} component.pkg/Payload
        mkdir payload
        (cd payload && cat "$work/component.pkg/Payload" | gunzip | cpio -id 2>/dev/null)
        # cpio extracts SeaDrive.app/ directly (no Applications/ prefix)
        APPEX="payload/SeaDrive.app/Contents/PlugIns/SeaDrive File Provider.appex"
        if [[ ! -d "$APPEX" ]]; then
          echo "error: File Provider appex not found in official pkg; extracted:" >&2
          find payload -maxdepth 6 -name "*.appex" >&2
          exit 1
        fi
        cp -R "$APPEX" "$out"
      '';

    mkPkg = pkgName: app:
      runCommand pkgName
        { nativeBuildInputs = [ xar bomutils cpio gzip coreutils findutils ]; }
        ''
          payload=$(mktemp -d)
          mkdir -p $payload/Applications
          cp -R ${app}/Applications/SeaDrive.app $payload/Applications/

          build=$(mktemp -d)
          ( cd $payload && find . | cpio -o --format odc 2>/dev/null | gzip -9 ) > $build/Payload
          mkbom -u 0 -g 80 $payload $build/Bom

          numfiles=$(find $payload | wc -l | tr -d ' ')
          kbytes=$(du -sk $payload | cut -f1)
          cat > $build/PackageInfo <<EOF
<?xml version="1.0" encoding="utf-8"?>
<pkg-info format-version="2" identifier="com.seafile.seadrive" version="${version}" install-location="/" auth="root">
  <payload installKBytes="$kbytes" numberOfFiles="$numfiles"/>
</pkg-info>
EOF
          ( cd $build && xar --compression none -cf "$out" PackageInfo Bom Payload )
        '';

    seadrive-app = runCommand "seadrive-app-${version}"
      {
        nativeBuildInputs = [
          qt6.qtbase
          macdylibbundler
          cctools
          coreutils
          findutils
        ];
      }
      ''
        export PATH="${lib.makeBinPath [ qt6.qtbase macdylibbundler cctools ]}:$PATH"
        export OTOOL=otool
        export INSTALL_NAME_TOOL=install_name_tool
        export QT_PLUGIN_DIRS="${qtPluginDirs}"

        APP=$out/Applications/SeaDrive.app
        mkdir -p "$APP/Contents"
        cp ${bundleScript} $TMPDIR/bundle-seadrive.sh
        chmod +x $TMPDIR/bundle-seadrive.sh

        $TMPDIR/bundle-seadrive.sh \
          "$APP" \
          ${seadrive-gui} \
          macdeployqt \
          ${version} \
          ${infoPlist} \
          ${icnsDir} \
          ${fproviderAppex}
      '';

    seadrive-pkg = mkPkg "seadrive-${version}.pkg" seadrive-app;

    pkgUniversal =
      { appAarch64, appX86_64 }:
      let
        merged-app = runCommand "seadrive-app-universal-${version}"
          { nativeBuildInputs = [ cctools coreutils findutils ]; }
          ''
            cp ${../scripts/darwin/merge-universal.sh} $TMPDIR/merge.sh
            chmod +x $TMPDIR/merge.sh
            mkdir -p $out/Applications
            $TMPDIR/merge.sh \
              $out/Applications/SeaDrive.app \
              ${appAarch64}/Applications/SeaDrive.app \
              ${appX86_64}/Applications/SeaDrive.app
          '';
      in
        mkPkg "seadrive-${version}-universal.pkg" merged-app;

  in
  { inherit seadrive-fuse seadrive-gui seadrive-app seadrive-pkg pkgUniversal; }
