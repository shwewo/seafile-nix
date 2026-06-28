#!/usr/bin/env bash
# Bundle nix-built Seafile binaries into a relocatable Seafile.app (no /nix/store refs).
set -euo pipefail

APP="$1"
CLIENT_STORE="$2"
SHARED_STORE="$3"
MACDEPLOYQT="$4"
VERSION="$5"
INFO_PLIST="$6"
ICNS="$7"

OTOOL="${OTOOL:-otool}"
INSTALL_NAME_TOOL="${INSTALL_NAME_TOOL:-install_name_tool}"

MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
FW="$APP/Contents/Frameworks"
PLUGINS="$APP/Contents/Plugins"

mkdir -p "$MACOS" "$RES" "$FW" "$PLUGINS"

cp "$CLIENT_STORE/bin/.seafile-applet-wrapped" "$MACOS/seafile-applet"
cp "$SHARED_STORE/bin/seaf-daemon" "$RES/seaf-daemon"
chmod +x "$MACOS/seafile-applet" "$RES/seaf-daemon"

cp "$INFO_PLIST" "$APP/Contents/Info.plist"
cp "$ICNS" "$RES/seafile.icns"

"$MACDEPLOYQT" "$APP" -always-overwrite -codesign=-

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

copy_deps_recursive "$MACOS/seafile-applet"
copy_deps_recursive "$RES/seaf-daemon"

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

  curl="$(deps_of "$SHARED_STORE/bin/seaf-daemon" | grep 'libcurl' | head -1)"
  idn2="$(deps_of "$curl" | grep 'libidn2' | head -1)"
  iconv="$(deps_of "$idn2" | grep 'libiconv' | head -1)"
  if [[ -z "$iconv" || ! -f "$iconv" ]]; then
    echo "error: could not locate GNU libiconv via libcurl/libidn2 chain" >&2
    exit 1
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

fix_binary "$MACOS/seafile-applet" executable
fix_binary "$RES/seaf-daemon" executable

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
if file "$MACOS/seafile-applet" | grep -vq "$want_arch"; then
  echo "error: seafile-applet is not $want_arch: $(file "$MACOS/seafile-applet")" >&2
  exit 1
fi

echo "bundled $APP ($VERSION)"