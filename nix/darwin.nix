# macOS packaging: .app bundle, and a .dmg disk image built from it.
# Apple Silicon (aarch64-darwin) only — see ../flake.nix's `systems` list.
{
  pkgs,
  lib,
  version,
  seafile-client,
  seafile-shared,
  seafileClientSrc,
}:

let
  inherit (pkgs) runCommand qt6 macdylibbundler cctools coreutils findutils fetchurl;

  # Extract FinderSync extension from the official Seafile macOS DMG.
  # The appex is built with Xcode in upstream releases; our cmake client
  # build only needs the host-side mach-port listener (HAVE_FINDER_SYNC_SUPPORT).
  officialDmg = fetchurl {
    url = "https://sos-ch-dk-2.exo.io/seafile-downloads/seafile-client-9.0.19.dmg";
    sha256 = "72b705bd3ec7142bca6fce7f069b4fe256066473f9368a9236a7b4e4e0189bd9";
  };

  findersyncAppex = runCommand "seafile-findersync-appex"
    { nativeBuildInputs = [ coreutils findutils ]; }
    ''
      work=$(mktemp -d)
      mountpoint="$work/mnt"
      mkdir -p "$mountpoint"
      /usr/bin/hdiutil attach ${officialDmg} -nobrowse -readonly -mountpoint "$mountpoint"
      APPEX="$mountpoint/Seafile Client.app/Contents/PlugIns/Seafile FinderSync.appex"
      if [[ ! -d "$APPEX" ]]; then
        echo "error: FinderSync appex not found in official dmg; extracted:" >&2
        find "$mountpoint" -maxdepth 8 -name "*.appex" >&2
        /usr/bin/hdiutil detach "$mountpoint" 2>/dev/null || true
        exit 1
      fi
      cp -R "$APPEX" "$out"
      /usr/bin/hdiutil detach "$mountpoint"
    '';

  bundleScript = ../scripts/darwin/bundle.sh;
  infoPlist = "${seafileClientSrc}/Info.plist";
  icns = "${seafileClientSrc}/seafile.icns";

  qtPluginDirs = lib.concatStringsSep ":" [
    "${qt6.qtbase}/lib/qt-6/plugins"
    "${qt6.qtsvg}/lib/qt-6/plugins"
    "${qt6.qtdeclarative}/lib/qt-6/plugins"
    "${qt6.qt5compat}/lib/qt-6/plugins"
  ];

  # Wrap a Seafile.app directory tree in a standard drag-to-Applications
  # .dmg: the .app plus an /Applications symlink side by side at the volume
  # root. Built with the real hdiutil on the macOS builder (same pattern as
  # findersyncAppex above reading one) — there's no pure-Nix way to produce
  # the UDIF disk-image format, so this step is inherently impure/darwin-only.
  mkDmg =
    dmgName: app:
    runCommand dmgName
      {
        nativeBuildInputs = [ coreutils findutils ];
      }
      ''
        payload=$(mktemp -d)
        cp -R ${app}/Applications/Seafile.app "$payload/Seafile.app"
        ln -s /Applications "$payload/Applications"
        /usr/bin/hdiutil create -volname "Seafile" -srcfolder "$payload" -ov -format UDZO "$out"
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
        ${icns} \
        ${findersyncAppex}
    '';

  seafile-dmg = mkDmg "seafile-${version}.dmg" seafile-app;

in
{
  inherit seafile-app seafile-dmg;
}