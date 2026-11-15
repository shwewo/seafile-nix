#!/usr/bin/env bash
# Check whether a component can be bumped to a new upstream tag.
#
#   scripts/check-bump.sh <component> [tag]     check (tag defaults to the latest)
#   scripts/check-bump.sh <component> <tag> --update
#                                                also write rev + hash into flake.nix
#                                                (only when the patch applies cleanly)
#   scripts/check-bump.sh regen <component> <dir>
#                                                after fixing rejects by hand in <dir>,
#                                                rewrite nix/patches/<component>-mtls.patch
#
# Components: seafile seafile-client seadrive-fuse seadrive-gui seadroid
#
# Needs: git, nix. Works without the GitHub API (hash comes from `git archive`,
# which matches what fetchFromGitHub downloads).
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
components="seafile seafile-client seadrive-fuse seadrive-gui seadroid"
nix_cmd=(nix --extra-experimental-features nix-command)

die() { echo "error: $*" >&2; exit 1; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

check_component() {
  case " $components " in
    *" $1 "*) ;;
    *) die "unknown component '$1' (one of: $components)" ;;
  esac
}

# Files the current patch touches, in order.
patch_files() {
  grep '^diff --git ' "$1" | awk '{ sub(/^b\//, "", $4); print $4 }'
}

# Current pin for a component, read from flake.nix: prints "rev hash".
current_pin() {
  awk -v c="$1" '
    $0 ~ "^ *" c " = \\{" { inblk = 1; next }
    inblk && /rev = /  { gsub(/[";]/, "", $3); rev = $3 }
    inblk && /hash = / { gsub(/[";]/, "", $3); hash = $3 }
    inblk && /^ *\};/  { print rev, hash; exit }
  ' "$repo_root/flake.nix"
}

# ── regen ────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "regen" ]]; then
  [[ $# -eq 3 ]] || die "usage: $0 regen <component> <dir>"
  comp=$2 dir=$3
  check_component "$comp"
  patch="$repo_root/nix/patches/$comp-mtls.patch"
  [[ -d "$dir/.git" ]] || die "$dir is not the work tree check-bump.sh printed"
  leftovers=$(cd "$dir" && find . -path ./.git -prune -o \( -name '*.rej' -o -name '*.orig' \) -print)
  [[ -z "$leftovers" ]] || die "remove these first (after merging them by hand):"$'\n'"$leftovers"
  mapfile -t files < <(patch_files "$patch")
  (cd "$dir" && git add -N . && git diff -- "${files[@]}") > "$patch.new"
  [[ -s "$patch.new" ]] || { rm -f "$patch.new"; die "empty diff, nothing to write"; }
  mv "$patch.new" "$patch"
  bold "Rewrote nix/patches/$comp-mtls.patch (${#files[@]} files, same as before)."
  echo "Now run:  scripts/check-bump.sh $comp $(cd "$dir" && git describe --tags --exact-match 2>/dev/null || echo '<tag>') --update"
  exit 0
fi

# ── check ────────────────────────────────────────────────────────────────────
[[ $# -ge 1 ]] || die "usage: $0 <component> [tag] [--update]   (or: $0 regen <component> <dir>)"
comp=$1; tag=${2:-}; update=false
[[ "${3:-}" == "--update" || "${2:-}" == "--update" ]] && update=true
[[ "$tag" == "--update" ]] && tag=""
check_component "$comp"

url="https://github.com/haiwen/$comp"
patch="$repo_root/nix/patches/$comp-mtls.patch"
read -r cur_rev cur_hash < <(current_pin "$comp")

if [[ -z "$tag" ]]; then
  tag=$(git ls-remote --tags --refs "$url" | awk '{ sub("refs/tags/", "", $2); print $2 }' \
        | grep -E '^v[0-9]+(\.[0-9]+)*$' | sort -V | tail -1)
  [[ -n "$tag" ]] || die "could not list tags for $url"
fi

bold "$comp: $cur_rev -> $tag"
[[ "$tag" == "$cur_rev" ]] && echo "(already pinned to $tag; checking anyway)"
case "$comp" in
  seafile|seafile-client)
    echo "note: seafile and seafile-client must be on the same tag; bump both." ;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/check-bump-$comp-XXXX")
git clone -q --depth 1 --branch "$tag" "$url" "$work/src" 2>/dev/null \
  || die "could not clone $url at tag $tag"

# Hash exactly the way fetchFromGitHub sees the source.
mkdir "$work/source"
git -C "$work/src" archive --format=tar HEAD | tar -x -C "$work/source"
hash=$("${nix_cmd[@]}" hash path "$work/source")
rm -rf "$work/source"
echo "hash: $hash"

cd "$work/src"
if git apply --check "$patch" 2>/dev/null; then
  bold "OK: the mTLS patch applies cleanly to $tag."
  if $update; then
    sed -i "/^ *$comp = {/,/^ *};/{s|rev = \"[^\"]*\"|rev = \"$tag\"|;s|hash = \"[^\"]*\"|hash = \"$hash\"|}" \
      "$repo_root/flake.nix"
    echo "Updated flake.nix. Next: nix build .#$comp-src, then a full build, then the mTLS test checklist."
  else
    echo "Re-run with --update to write it into flake.nix."
  fi
  rm -rf "$work"
  exit 0
fi

# Patch failed: apply what we can, then explain each rejected hunk.
git apply --reject "$patch" >/dev/null 2>&1 || true
bold "The patch does NOT apply cleanly. Rejected hunks:"
needs_review=false
while IFS= read -r rej; do
  file=${rej%.rej}; file=${file#./}
  # Split the .rej into hunks; a hunk is "moved" when every line it removes
  # or keeps as context still exists somewhere in the new upstream file.
  awk -v out="$work/hunk" '/^@@/ { n++ } n { print > (out "." n) }' "$rej"
  for h in "$work"/hunk.*; do
    header=$(head -1 "$h")
    missing=0
    while IFS= read -r line; do
      [[ -z "${line// }" ]] && continue
      grep -qxF -- "$line" "$file" || missing=$((missing + 1))
    done < <(tail -n +2 "$h" | grep -E '^[ -]' | cut -c2-)
    case "$file" in *.c|*.h|*.cpp|*.mm) lang="C/C++" ;; *) lang="" ;; esac
    if [[ $missing -eq 0 ]]; then
      echo "  [moved]        $file  $header"
      echo "                 upstream code is still there, just shifted: copy the + lines in by hand."
    else
      needs_review=true
      echo "  [NEEDS REVIEW] $file  $header"
      echo "                 $missing line(s) the patch expects are gone: upstream changed this code."
      [[ -n "$lang" ]] && echo "                 This is $lang: get the result reviewed (see MAINTAINING.md)."
    fi
    rm -f "$h"
  done
done < <(find . -path ./.git -prune -o -name '*.rej' -print | sort)

echo
echo "Work tree with the clean hunks applied and *.rej files: $work/src"
echo "1. For each .rej, apply its + lines to the file by hand, then delete the .rej."
echo "2. scripts/check-bump.sh regen $comp $work/src"
echo "3. scripts/check-bump.sh $comp $tag --update"
$needs_review && echo "Some hunks need real review; don't just force them in."
exit 1
