#!/usr/bin/env bash
# Check whether components can be bumped to new upstream tags.
#
#   scripts/check-bump.sh                         check every component at its latest tag
#   scripts/check-bump.sh seafile seadroid        check some components (latest tags)
#   scripts/check-bump.sh seafile@v9.0.23 seafile-client@v9.0.23
#                                                 check specific tags
#   scripts/check-bump.sh seadrive-gui v3.0.28    (old form: "<component> <tag>" also works)
#   ... --update                                  also write rev + hash into flake.nix for
#                                                 each component whose patch applies cleanly
#   scripts/check-bump.sh regen <component> <dir>
#                                                 after fixing rejects by hand in <dir>,
#                                                 rewrite nix/patches/<component>-mtls.patch
#
# Components: seafile seafile-client seadrive-fuse seadrive-gui seadroid
# Exit code: 0 if every checked patch applies cleanly, 1 otherwise.
#
# Needs: git, nix. Works without the GitHub API (hash comes from `git archive`,
# which matches what fetchFromGitHub downloads).
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
components="seafile seafile-client seadrive-fuse seadrive-gui seadroid"
nix_cmd=(nix --extra-experimental-features nix-command)

die() { echo "error: $*" >&2; exit 1; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

is_component() { [[ " $components " == *" $1 "* ]]; }
check_component() { is_component "$1" || die "unknown component '$1' (one of: $components)"; }

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

latest_tag() {
  git ls-remote --tags --refs "https://github.com/haiwen/$1" \
    | awk '{ sub("refs/tags/", "", $2); print $2 }' \
    | grep -E '^v[0-9]+(\.[0-9]+)*$' | sort -V | tail -1
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
  echo "Now run:  scripts/check-bump.sh $comp@$(cd "$dir" && git describe --tags --exact-match 2>/dev/null || echo '<tag>') --update"
  exit 0
fi

# ── check one component ──────────────────────────────────────────────────────
# Prints a report and appends one line to the summary.
# Returns 0 = applies cleanly, 1 = rejects (all [moved]), 2 = rejects needing review, 3 = error.
summary=()
declare -A chosen_tag=()

check_one() {
  local comp=$1 tag=$2 cur_rev cur_hash url patch work hash needs_review=false rej file h header missing lang line

  url="https://github.com/haiwen/$comp"
  patch="$repo_root/nix/patches/$comp-mtls.patch"
  read -r cur_rev cur_hash < <(current_pin "$comp")

  echo
  if [[ -z "$tag" ]]; then
    tag=$(latest_tag "$comp") || true
    if [[ -z "$tag" ]]; then
      echo "error: could not list tags for $url"
      summary+=("$(printf '%-15s %-9s %-9s %s' "$comp" "$cur_rev" "?" "ERROR (could not list tags)")")
      return 3
    fi
  fi
  chosen_tag[$comp]=$tag

  bold "══ $comp: $cur_rev -> $tag"
  if [[ "$tag" == "$cur_rev" ]]; then
    echo "(already pinned to $tag; checking anyway)"
  fi

  work=$(mktemp -d "${TMPDIR:-/tmp}/check-bump-$comp-XXXX")
  if ! git clone -q --depth 1 --branch "$tag" "$url" "$work/src" 2>/dev/null; then
    echo "error: could not clone $url at tag $tag"
    rm -rf "$work"
    summary+=("$(printf '%-15s %-9s %-9s %s' "$comp" "$cur_rev" "$tag" "ERROR (no such tag?)")")
    return 3
  fi

  # Hash exactly the way fetchFromGitHub sees the source.
  mkdir "$work/source"
  git -C "$work/src" archive --format=tar HEAD | tar -x -C "$work/source"
  hash=$("${nix_cmd[@]}" hash path "$work/source")
  rm -rf "$work/source"
  echo "hash: $hash"

  if git -C "$work/src" apply --check "$patch" 2>/dev/null; then
    echo "OK: the mTLS patch applies cleanly."
    if $update; then
      sed -i "/^ *$comp = {/,/^ *};/{s|rev = \"[^\"]*\"|rev = \"$tag\"|;s|hash = \"[^\"]*\"|hash = \"$hash\"|}" \
        "$repo_root/flake.nix"
      echo "Updated flake.nix."
      summary+=("$(printf '%-15s %-9s %-9s %s' "$comp" "$cur_rev" "$tag" "OK, flake.nix updated")")
    else
      summary+=("$(printf '%-15s %-9s %-9s %s' "$comp" "$cur_rev" "$tag" "OK")")
    fi
    rm -rf "$work"
    return 0
  fi

  # Patch failed: apply what we can, then explain each rejected hunk.
  git -C "$work/src" apply --reject "$patch" >/dev/null 2>&1 || true
  echo "The patch does NOT apply cleanly. Rejected hunks:"
  while IFS= read -r rej; do
    file=${rej%.rej}
    # Split the .rej into hunks; a hunk is "moved" when every line it removes
    # or keeps as context still exists somewhere in the new upstream file.
    awk -v out="$work/hunk" '/^@@/ { n++ } n { print > (out "." n) }' "$work/src/$rej"
    for h in "$work"/hunk.*; do
      header=$(head -1 "$h")
      missing=0
      while IFS= read -r line; do
        [[ -z "${line// }" ]] && continue
        grep -qxF -- "$line" "$work/src/$file" || missing=$((missing + 1))
      done < <(tail -n +2 "$h" | grep -E '^[ -]' | cut -c2-)
      case "$file" in *.c|*.h|*.cpp|*.mm) lang="C/C++" ;; *) lang="" ;; esac
      if [[ $missing -eq 0 ]]; then
        echo "  [moved]        $file  $header"
        echo "                 upstream code is still there, just shifted: copy the + lines in by hand."
      else
        needs_review=true
        echo "  [NEEDS REVIEW] $file  $header"
        echo "                 $missing line(s) the patch expects are gone: upstream changed this code."
        if [[ -n "$lang" ]]; then
          echo "                 This is $lang: get the result reviewed (see MAINTAINING.md)."
        fi
      fi
      rm -f "$h"
    done
  done < <(cd "$work/src" && find . -path ./.git -prune -o -name '*.rej' -print | sed 's|^\./||' | sort)

  echo "Work tree with the clean hunks applied and *.rej files: $work/src"
  echo "  1. For each .rej, apply its + lines to the file by hand, then delete the .rej."
  echo "  2. scripts/check-bump.sh regen $comp $work/src"
  echo "  3. scripts/check-bump.sh $comp@$tag --update"
  if $needs_review; then
    summary+=("$(printf '%-15s %-9s %-9s %s' "$comp" "$cur_rev" "$tag" "NEEDS REVIEW  $work/src")")
    return 2
  fi
  summary+=("$(printf '%-15s %-9s %-9s %s' "$comp" "$cur_rev" "$tag" "rejects (moved only)  $work/src")")
  return 1
}

# ── parse arguments ──────────────────────────────────────────────────────────
update=false
targets=()   # "component tag" pairs; tag may be empty (= latest)
for arg in "$@"; do
  case "$arg" in
    --update) update=true ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *@*)
      check_component "${arg%%@*}"
      targets+=("${arg%%@*} ${arg#*@}") ;;
    v[0-9]*)
      # Old form "<component> <tag>": attach the tag to the previous component.
      [[ ${#targets[@]} -gt 0 ]] || die "tag '$arg' given before any component"
      last=${targets[-1]}
      [[ "$last" == *" " ]] || die "component '${last% *}' already has a tag"
      targets[-1]="$last$arg" ;;
    *)
      check_component "$arg"
      targets+=("$arg ") ;;
  esac
done
if [[ ${#targets[@]} -eq 0 ]]; then
  for c in $components; do targets+=("$c "); done
fi

# ── run ──────────────────────────────────────────────────────────────────────
worst=0
for t in "${targets[@]}"; do
  rc=0
  check_one "${t%% *}" "${t#* }" || rc=$?
  (( rc > worst )) && worst=$rc
done

echo
bold "══ Summary"
printf '%-15s %-9s %-9s %s\n' "component" "pinned" "checked" "result"
printf '%s\n' "${summary[@]}"

# seafile and seafile-client must stay on the same tag.
core_tag=${chosen_tag[seafile]:-$(current_pin seafile | cut -d' ' -f1)}
client_tag=${chosen_tag[seafile-client]:-$(current_pin seafile-client | cut -d' ' -f1)}
if [[ "$core_tag" != "$client_tag" ]]; then
  echo
  echo "warning: seafile ($core_tag) and seafile-client ($client_tag) must be on the same tag;"
  echo "         check and bump them together."
fi

if (( worst == 2 )); then
  echo
  echo "Some hunks need real review; don't just force them in (see MAINTAINING.md)."
fi
(( worst == 0 ))