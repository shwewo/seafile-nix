#!/usr/bin/env bash
# Merge arm64 and x86_64 Seafile.app trees into one universal app bundle.
set -euo pipefail

OUT_APP="$1"
ARM_APP="$2"
X86_APP="$3"

OTOOL="${OTOOL:-otool}"
LIPO="${LIPO:-lipo}"

if [[ ! -d "$ARM_APP" || ! -d "$X86_APP" ]]; then
  echo "error: both arch-specific .app bundles are required" >&2
  exit 1
fi

is_macho() {
  file "$1" 2>/dev/null | grep -q "Mach-O"
}

rm -rf "$OUT_APP"
cp -R "$ARM_APP" "$OUT_APP"
chmod -R u+w "$OUT_APP"

while IFS= read -r -d '' arm_file; do
  relpath="${arm_file#"$ARM_APP"/}"
  x86_file="$X86_APP/$relpath"
  out_file="$OUT_APP/$relpath"

  if is_macho "$arm_file"; then
    if [[ ! -f "$x86_file" ]] || ! is_macho "$x86_file"; then
      echo "error: Mach-O mismatch for $relpath" >&2
      exit 1
    fi
    tmp="$(mktemp)"
    "$LIPO" -create "$arm_file" "$x86_file" -output "$tmp"
    mv "$tmp" "$out_file"
  fi
done < <(find "$ARM_APP" -type f -print0)

applet="$OUT_APP/Contents/MacOS/seafile-applet"
daemon="$OUT_APP/Contents/Resources/seaf-daemon"

for bin in "$applet" "$daemon"; do
  if ! "$LIPO" -info "$bin" | grep -q "Architectures in the fat file"; then
    echo "error: $bin is not a universal binary: $("$LIPO" -info "$bin")" >&2
    exit 1
  fi
  if ! "$LIPO" -info "$bin" | grep -q "arm64"; then
    echo "error: $bin missing arm64 slice" >&2
    exit 1
  fi
  if ! "$LIPO" -info "$bin" | grep -q "x86_64"; then
    echo "error: $bin missing x86_64 slice" >&2
    exit 1
  fi
done

check_clean() {
  local bin="$1"
  if "$OTOOL" -L "$bin" 2>/dev/null | awk '/^\t/ {print}' | grep -q '/nix/store'; then
    echo "error: $bin still references /nix/store" >&2
    exit 1
  fi
}

while IFS= read -r -d '' macho; do
  check_clean "$macho"
done < <(find "$OUT_APP" -type f -print0 | while IFS= read -r -d '' f; do
  is_macho "$f" && printf '%s\0' "$f"
done)

echo "merged universal $OUT_APP"