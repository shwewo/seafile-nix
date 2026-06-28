#!/usr/bin/env bash
# Bundle nix-built SeaDrive binaries into a relocatable SeaDrive.app (no /nix/store refs).
set -euo pipefail

APP="$1"
GUI_STORE="$2"
MACDEPLOYQT="$3"
VERSION="$4"
INFO_PLIST="$5"
ICNS_DIR="$6"
FPROVIDER_APPEX="${7:-}"  # optional: path to "SeaDrive File Provider.appex"

OTOOL="${OTOOL:-otool}"
INSTALL_NAME_TOOL="${INSTALL_NAME_TOOL:-install_name_tool}"

MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
FW="$APP/Contents/Frameworks"
PLUGINS="$APP/Contents/Plugins"

PLUGINSDIR="$APP/Contents/PlugIns"
mkdir -p "$MACOS" "$RES" "$FW" "$PLUGINS" "$PLUGINSDIR"

cp "$GUI_STORE/bin/seadrive-gui"  "$MACOS/seadrive-gui"
chmod +x "$MACOS/seadrive-gui"

cp "$INFO_PLIST" "$APP/Contents/Info.plist"
# Info.plist references CFBundleIconFile = "seadrive-icon"
cp "$ICNS_DIR/seadrive.icns"        "$RES/seadrive-icon.icns"
cp "$ICNS_DIR/locked-by-me.icns"   "$RES/locked-by-me.icns"
cp "$ICNS_DIR/locked-by-user.icns" "$RES/locked-by-user.icns"

# Ensure all app contents are writable so macdeployqt/strip can modify them.
chmod -R u+w "$APP"

# Deploy Qt frameworks; ignore signing failures (sign separately if needed).
set +e
"$MACDEPLOYQT" "$APP" -always-overwrite 2>&1 | grep -v "Codesign signing error\|codesign verification\|^ERROR: \"\"$"
DEPLOY_EXIT=$?
set -e
if [[ $DEPLOY_EXIT -ne 0 ]]; then
  echo "note: macdeployqt exited $DEPLOY_EXIT (likely codesign-only; continuing)" >&2
fi

is_syslib() {
  case "$1" in
    /usr/lib/*|/System/*|@executable_path/*|@loader_path/*|@rpath/*) return 0 ;;
  esac
  return 1
}

deps_of() {
  "$OTOOL" -L "$1" 2>/dev/null | awk '/^\t/ {print $1}' | while read -r dep; do
    is_syslib "$dep" && continue
    echo "$dep"
  done
}

dylib_current_version() {
  "$OTOOL" -L "$1" 2>/dev/null | head -1 | sed -n 's/.*current version \([0-9.]*\).*/\1/p'
}

version_gt() {
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" && "$1" != "$2" ]]
}

copy_dep() {
  local dep="$1"
  local base
  base="$(basename "$dep")"
  local dst="$FW/$base"
  [[ -e "$dep" ]] || return 0
  if [[ -e "$dst" ]]; then
    local old_ver new_ver
    old_ver="$(dylib_current_version "$dst")"
    new_ver="$(dylib_current_version "$dep")"
    if [[ -n "$old_ver" && -n "$new_ver" ]] && version_gt "$new_ver" "$old_ver"; then
      cp "$dep" "$dst"
      chmod +w "$dst"
      echo "$dst"
    fi
    return 0
  fi
  if [[ -d "$dep" ]]; then
    cp -R "$dep" "$dst"
  else
    cp "$dep" "$dst"
    chmod +w "$dst"
  fi
  echo "$dst"
}

copy_deps_recursive() {
  local root="$1"
  local -a queue=("$root")
  local -A seen=()

  while ((${#queue[@]})); do
    local item="${queue[0]}"
    queue=("${queue[@]:1}")
    [[ -n "${seen[$item]:-}" ]] && continue
    seen[$item]=1

    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      local copied
      copied="$(copy_dep "$dep")"
      [[ -n "$copied" ]] && queue+=("$copied")
      [[ "$dep" == /nix/store/* ]] && queue+=("$dep")
    done < <(deps_of "$item")
  done
}

copy_deps_recursive "$MACOS/seadrive-gui"

add_rpath() {
  local bin="$1" relpath="$2"
  if ! "$OTOOL" -l "$bin" 2>/dev/null | grep -q "path $relpath"; then
    "$INSTALL_NAME_TOOL" -add_rpath "$relpath" "$bin" 2>/dev/null || true
  fi
}

fix_binary() {
  local bin="$1"
  local mode="${2:-executable}"
  local rpath="@executable_path/../Frameworks"
  [[ "$mode" == "library" ]] && rpath="@loader_path/../Frameworks"

  add_rpath "$bin" "$rpath"
  "$INSTALL_NAME_TOOL" -delete_rpath /usr/local/lib "$bin" 2>/dev/null || true
  "$INSTALL_NAME_TOOL" -delete_rpath /opt/local/lib "$bin" 2>/dev/null || true

  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    is_syslib "$dep" && continue
    local base
    base="$(basename "$dep")"
    if [[ -e "$FW/$base" ]]; then
      "$INSTALL_NAME_TOOL" -change "$dep" "@rpath/$base" "$bin"
    fi
  done < <(deps_of "$bin")
}

reconcile_libiconv() {
  local sys="/usr/lib/libiconv.2.dylib"
  local gnu="$FW/libgnuiconv.2.dylib"
  local curl idn2 iconv

  curl="$(deps_of "$MACOS/seadrive-gui" | grep 'libcurl' | head -1 || true)"
  idn2="$(deps_of "$curl" 2>/dev/null | grep 'libidn2' | head -1 || true)"
  iconv=""
  [[ -n "$idn2" ]] && iconv="$(deps_of "$idn2" | grep 'libiconv' | head -1 || true)"
  if [[ -z "$iconv" || ! -f "$iconv" ]]; then
    echo "note: GNU libiconv not found via libcurl/libidn2 chain — skipping libiconv reconciliation" >&2
    return 0
  fi

  cp "$iconv" "$gnu"
  chmod +w "$gnu"
  "$INSTALL_NAME_TOOL" -id "@rpath/libgnuiconv.2.dylib" "$gnu"
  add_rpath "$gnu" "@loader_path/../Frameworks"
  rm -f "$FW/libiconv.2.dylib"

  uses_system_libiconv() {
    case "$(basename "$1")" in
      libglib-2.0.0.dylib|libintl.8.dylib) return 0 ;;
    esac
    return 1
  }

  while IFS= read -r -d '' macho; do
    file "$macho" | grep -q "Mach-O" || continue
    [[ "$(basename "$macho")" == "libgnuiconv.2.dylib" ]] && continue

    local target="@rpath/libgnuiconv.2.dylib"
    uses_system_libiconv "$macho" && target="$sys"

    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      case "$dep" in
        *libiconv*) "$INSTALL_NAME_TOOL" -change "$dep" "$target" "$macho" ;;
      esac
    done < <("$OTOOL" -L "$macho" 2>/dev/null | awk '/^\t/ {print $1}')
  done < <(find "$APP" -type f -print0)
}

fix_binary "$MACOS/seadrive-gui" executable

while IFS= read -r lib; do
  [[ -f "$lib" ]] || continue
  "$INSTALL_NAME_TOOL" -id "@rpath/$(basename "$lib")" "$lib" 2>/dev/null || true
  fix_binary "$lib" library
done < <(find "$FW" -maxdepth 1 -type f)

if [[ -n "${QT_PLUGIN_DIRS:-}" ]]; then
  IFS=':' read -r -a _qt_plugin_roots <<< "$QT_PLUGIN_DIRS"
  for plugin_root in "${_qt_plugin_roots[@]}"; do
    [[ -d "$plugin_root" ]] || continue
    for category in platforms iconengines imageformats styles tls; do
      [[ -d "$plugin_root/$category" ]] || continue
      mkdir -p "$PLUGINS/$category"
      cp -Rf "$plugin_root/$category/." "$PLUGINS/$category/"
    done
  done
  fix_plugin() {
    local plug="$1"
    local fw_prefix="@loader_path/../../Frameworks"
    add_rpath "$plug" "$fw_prefix"
    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      case "$dep" in
        /nix/store/*)
          if [[ "$dep" == *"/lib/"* ]]; then
            local tail="${dep#*/lib/}"
            "$INSTALL_NAME_TOOL" -change "$dep" "$fw_prefix/$tail" "$plug"
          else
            "$INSTALL_NAME_TOOL" -change "$dep" "$fw_prefix/$(basename "$dep")" "$plug"
          fi
          ;;
      esac
    done < <(deps_of "$plug")
  }

  while IFS= read -r -d '' plug; do
    fix_plugin "$plug"
  done < <(find "$PLUGINS" -name '*.dylib' -print0)
fi

reconcile_libiconv

check_clean() {
  local bin="$1"
  if "$OTOOL" -L "$bin" 2>/dev/null | awk '/^\t/ {print}' | grep -q '/nix/store'; then
    echo "error: $bin still references /nix/store:" >&2
    "$OTOOL" -L "$bin" | awk '/^\t/ {print}' | grep '/nix/store' >&2 || true
    exit 1
  fi
}

machos=()
while IFS= read -r -d '' f; do
  file "$f" | grep -q "Mach-O" && machos+=("$f")
done < <(find "$APP" -type f -print0)

for macho in "${machos[@]}"; do
  check_clean "$macho"
done

host_arch="$(uname -m)"
case "$host_arch" in
  arm64) want_arch=arm64 ;;
  x86_64) want_arch=x86_64 ;;
  *)
    echo "error: unsupported build host architecture: $host_arch" >&2
    exit 1
    ;;
esac
if file "$MACOS/seadrive-gui" | grep -vq "$want_arch"; then
  echo "error: seadrive-gui is not $want_arch: $(file "$MACOS/seadrive-gui")" >&2
  exit 1
fi

if [[ -n "$FPROVIDER_APPEX" && -d "$FPROVIDER_APPEX" ]]; then
  cp -R "$FPROVIDER_APPEX" "$PLUGINSDIR/SeaDrive File Provider.appex"
  echo "included File Provider extension"
fi

echo "bundled $APP ($VERSION)"
