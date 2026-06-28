# macOS packaging: .app bundle, single-arch .pkg, and universal .pkg merge.
{
  pkgs,
  lib,
  version,
  seafile-client,
  seafile-shared,
  seafileClientSrc,
}:

let
  inherit (pkgs) runCommand qt6 macdylibbundler cctools coreutils findutils;
  inherit (pkgs)
    xar
    bomutils
    cpio
    gzip
    ;

  bundleScript = ../scripts/darwin/bundle.sh;
  mergeScript = ../scripts/darwin/merge-universal.sh;
  infoPlist = "${seafileClientSrc}/Info.plist";
  icns = "${seafileClientSrc}/seafile.icns";

  qtPluginDirs = lib.concatStringsSep ":" [
    "${qt6.qtbase}/lib/qt-6/plugins"
    "${qt6.qtsvg}/lib/qt-6/plugins"
    "${qt6.qtdeclarative}/lib/qt-6/plugins"
    "${qt6.qt5compat}/lib/qt-6/plugins"
  ];

  # Wrap a Seafile.app directory tree in a macOS installer .pkg.
  mkPkg =
    pkgName: app:
    runCommand pkgName
      {
        nativeBuildInputs = [ xar bomutils cpio gzip coreutils findutils ];
      }
      ''
        payload=$(mktemp -d)
        mkdir -p $payload/Applications
        cp -R ${app}/Applications/Seafile.app $payload/Applications/

        build=$(mktemp -d)
        ( cd $payload && find . | cpio -o --format odc 2>/dev/null | gzip -9 ) > $build/Payload
        mkbom -u 0 -g 80 $payload $build/Bom

        numfiles=$(find $payload | wc -l | tr -d ' ')
        kbytes=$(du -sk $payload | cut -f1)
        cat > $build/PackageInfo <<EOF
<?xml version="1.0" encoding="utf-8"?>
<pkg-info format-version="2" identifier="com.seafile.seafile-client" version="${version}" install-location="/" auth="root">
  <payload installKBytes="$kbytes" numberOfFiles="$numfiles"/>
</pkg-info>
EOF
        ( cd $build && xar --compression none -cf "$out" PackageInfo Bom Payload )
      '';

  seafile-app = runCommand "seafile-app-${version}"
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

      APP=$out/Applications/Seafile.app
      mkdir -p "$APP/Contents"
      cp ${bundleScript} $TMPDIR/bundle.sh
      chmod +x $TMPDIR/bundle.sh

      $TMPDIR/bundle.sh \
        "$APP" \
        ${seafile-client} \
        ${seafile-shared} \
        macdeployqt \
        ${version} \
        ${infoPlist} \
        ${icns}
    '';

  seafile-pkg = mkPkg "seafile-${version}.pkg" seafile-app;

  pkgUniversal =
    {
      appAarch64,
      appX86_64,
    }:
    let
      merged-app = runCommand "seafile-app-universal-${version}"
        {
          nativeBuildInputs = [ cctools coreutils findutils ];
        }
        ''
          cp ${mergeScript} $TMPDIR/merge.sh
          chmod +x $TMPDIR/merge.sh
          mkdir -p $out/Applications
          $TMPDIR/merge.sh \
            $out/Applications/Seafile.app \
            ${appAarch64}/Applications/Seafile.app \
            ${appX86_64}/Applications/Seafile.app
        '';
    in
    mkPkg "seafile-${version}-universal.pkg" merged-app;

in
{
  inherit seafile-app seafile-pkg pkgUniversal;
}