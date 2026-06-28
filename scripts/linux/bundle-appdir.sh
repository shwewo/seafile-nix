#!/usr/bin/env bash
# Bundle nix-built Seafile binaries into a relocatable AppDir (no /nix/store refs).
set -euo pipefail

APPDIR="$1"
CLIENT_STORE="$2"
SHARED_STORE="$3"
QT_BASE="$4"
VERSION="$5"
DESKTOP_FILE="$6"
ICON_FILE="$7"

PATCHELF="${PATCHELF:-patchelf}"

mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/plugins" "$APPDIR/usr/share/applications"

cp "$CLIENT_STORE/bin/.seafile-applet-wrapped" "$APPDIR/usr/bin/seafile-applet"
cp "$SHARED_STORE/bin/seaf-daemon" "$APPDIR/usr/bin/seaf-daemon"
chmod u+w,+x "$APPDIR/usr/bin/seafile-applet" "$APPDIR/usr/bin/seaf-daemon"

cp "$DESKTOP_FILE" "$APPDIR/seafile.desktop"
cp "$DESKTOP_FILE" "$APPDIR/usr/share/applications/seafile.desktop"
cp "$ICON_FILE" "$APPDIR/seafile.png"

is_syslib() {
  case "$1" in
    /lib/*|/lib64/*|/usr/lib/*|/usr/lib64/*) return 0 ;;
  esac
  return 1
}

resolve_soname() {
  local soname="$1"
  local dir
  IFS=: read -ra lib_dirs <<< "${LD_LIBRARY_PATH:-}"
  for dir in "${lib_dirs[@]}"; do
    if [[ -e "$dir/$soname" ]]; then
      echo "$dir/$soname"
      return 0
    fi
  done
  return 1
}

deps_of() {
  readelf -d "$1" 2>/dev/null | awk '/NEEDED/ {gsub(/[\[\]]/, "", $5); print $5}' | while read -r soname; do
    [[ -z "$soname" ]] && continue
    case "$soname" in
      ld-linux*.so.*|linux-vdso.so.1) continue ;;
    esac
    local dep
    dep="$(resolve_soname "$soname" || true)"
    [[ -z "$dep" ]] && continue
    is_syslib "$dep" && continue
    echo "$dep"
  done
}

copy_dep() {
  local dep="$1"
  local base
  base="$(basename "$dep")"
  local dst="$APPDIR/usr/lib/$base"
  [[ -e "$dep" ]] || return 0
  [[ -e "$dst" ]] && return 0
  cp -L "$dep" "$dst"
  chmod u+w "$dst"
  "$PATCHELF" --remove-rpath "$dst" 2>/dev/null || true
  "$PATCHELF" --set-rpath '$ORIGIN' "$dst" 2>/dev/null || true
}

copy_deps_recursive() {
  local root="$1"
  local -a queue=("$root")
  local seen
  seen="$(mktemp)"
  trap 'rm -f "$seen"' RETURN

  while ((${#queue[@]})); do
    local item="${queue[0]}"
    queue=("${queue[@]:1}")
    grep -Fxq "$item" "$seen" 2>/dev/null && continue
    echo "$item" >> "$seen"

    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      copy_dep "$dep"
      [[ "$dep" == /nix/store/* ]] && queue+=("$dep")
    done < <(deps_of "$item")
  done
}

copy_deps_recursive "$APPDIR/usr/bin/seafile-applet"
copy_deps_recursive "$APPDIR/usr/bin/seaf-daemon"

# Qt platform/plugins the applet needs at runtime.
for category in platforms iconengines imageformats styles tls; do
  [[ -d "$QT_BASE/lib/qt-6/plugins/$category" ]] || continue
  mkdir -p "$APPDIR/usr/plugins/$category"
  cp -Rf "$QT_BASE/lib/qt-6/plugins/$category/." "$APPDIR/usr/plugins/$category/"
done
chmod -R u+w "$APPDIR/usr/plugins"

fix_elf_rpath() {
  local elf="$1"
  local rpath="$2"
  chmod u+w "$elf"
  "$PATCHELF" --remove-rpath "$elf" 2>/dev/null || true
  "$PATCHELF" --set-rpath "$rpath" "$elf"
}

fix_binary() {
  local bin="$1"
  local rpath="${2:-\$ORIGIN/../lib}"
  fix_elf_rpath "$bin" "$rpath"
  readelf -d "$bin" 2>/dev/null | awk '/NEEDED/ {gsub(/[\[\]]/, "", $5); print $5}' | while read -r name; do
    [[ -z "$name" ]] && continue
    if [[ -e "$APPDIR/usr/lib/$name" ]]; then
      "$PATCHELF" --replace-needed "$name" "$name" "$bin" 2>/dev/null || true
    fi
  done
}

fix_binary "$APPDIR/usr/bin/seafile-applet"
fix_binary "$APPDIR/usr/bin/seaf-daemon"

while IFS= read -r -d '' plug; do
  copy_deps_recursive "$plug"
  fix_binary "$plug" '$ORIGIN/../../lib'
done < <(find "$APPDIR/usr/plugins" -name '*.so' -print0 2>/dev/null)

while IFS= read -r -d '' lib; do
  fix_elf_rpath "$lib" '$ORIGIN'
done < <(find "$APPDIR/usr/lib" -name '*.so*' -print0 2>/dev/null)

cat > "$APPDIR/AppRun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
APPDIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$APPDIR/usr/bin:$PATH"
export LD_LIBRARY_PATH="$APPDIR/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export QT_PLUGIN_PATH="$APPDIR/usr/plugins"
exec "$APPDIR/usr/bin/seafile-applet" "$@"
EOF
chmod +x "$APPDIR/AppRun"

grep -q '^Exec=' "$APPDIR/seafile.desktop" && \
  sed -i 's|^Exec=.*|Exec=seafile-applet|' "$APPDIR/seafile.desktop" && \
  sed -i 's|^Exec=.*|Exec=seafile-applet|' "$APPDIR/usr/share/applications/seafile.desktop"

is_allowed_nix_ref() {
  case "$1" in
    */glibc-*/lib/*|*/glibc-*/lib64/*) return 0 ;;
    */gcc-*/lib/*|*/libgcc*) return 0 ;;
  esac
  return 1
}

check_clean() {
  local bin="$1"
  if readelf -d "$bin" 2>/dev/null | awk '/RUNPATH|RPATH/ {print}' | grep -q '/nix/store'; then
    echo "error: $bin still has nix store rpath:" >&2
    readelf -d "$bin" | awk '/RUNPATH|RPATH/' >&2
    exit 1
  fi
}

while IFS= read -r -d '' f; do
  file "$f" | grep -q "ELF" && check_clean "$f"
done < <(find "$APPDIR" -type f -print0)

echo "bundled AppDir $APPDIR ($VERSION)"