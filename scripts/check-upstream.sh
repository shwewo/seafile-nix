#!/usr/bin/env bash
# Checks every pin in flake.nix's `versions` block against the newest upstream
# release tag (vX.Y.Z) and tries that component's mTLS patch on it.
#
#   scripts/check-upstream.sh                 # report only, changes nothing
#   scripts/check-upstream.sh --open-github   # CI: open a PR for each new tag the patch
#                                             # applies to, an issue for each it doesn't
#
# A patch that "applies" only means every hunk found its place. It doesn't mean
# the code is still right, so a bump PR is a prompt to review the change, not
# something to merge blindly.
#
# seafile and seafile-client are moved together, to the newest tag both have
# (see CLAUDE.md, "Pins that aren't latest").
set -euo pipefail

cd "$(dirname "$0")/.."

OPEN_GITHUB=0
case "${1:-}" in
  --open-github) OPEN_GITHUB=1 ;;
  "") ;;
  *) echo "usage: $0 [--open-github]" >&2; exit 2 ;;
esac

# Groups of components bumped together, one group per line.
GROUPS_=(
  "seafile seafile-client"
  "seadrive-fuse"
  "seadrive-gui"
  "seadroid"
)

FLAKE_REF="git+file://$PWD"
VERSIONS=$(nix eval --json .#versions)
LOGDIR=$(mktemp -d)
trap 'rm -rf "$LOGDIR"' EXIT

field() { jq -r --arg n "$1" --arg f "$2" '.[$n][$f]' <<<"$VERSIONS"; }

release_tags() {
  git ls-remote --tags --refs "https://github.com/$1/$2" \
    | sed 's#.*refs/tags/##' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V
}

# Newest tag every component of the group has.
newest_common_tag() {
  local common="" name tags
  for name in "$@"; do
    tags=$(release_tags "$(field "$name" owner)" "$(field "$name" repo)")
    if [ -z "$common" ]; then common=$tags; else common=$(comm -12 <(sort <<<"$common") <(sort <<<"$tags")); fi
  done
  sort -V <<<"$common" | tail -1
}

prefetch() { # owner repo tag -> SRI hash, same as fetchFromGitHub
  local h
  h=$(nix-prefetch-url --unpack --type sha256 --name source \
      "https://github.com/$1/$2/archive/$3.tar.gz" 2>/dev/null)
  nix hash convert --hash-algo sha256 --to sri "$h"
}

# Applies <name>'s patch to <tag>, building only the patched source.
try_patch() { # name tag hash logfile
  OVERRIDE=$(jq -nc --arg name "$1" --arg rev "$2" --arg hash "$3" '{$name,$rev,$hash}') \
  FLAKE_REF="$FLAKE_REF" \
  nix build --impure --no-link -L --expr '
    let
      flake = builtins.getFlake (builtins.getEnv "FLAKE_REF");
      o = builtins.fromJSON (builtins.getEnv "OVERRIDE");
      pkgs = import flake.inputs.nixpkgs {
        system = builtins.currentSystem;
        config = { allowUnsupportedSystem = true; allowUnfree = true; android_sdk.accept_license = true; };
      };
      versions = flake.versions // {
        ${o.name} = flake.versions.${o.name} // { inherit (o) rev hash; };
      };
    in
    (import (flake.outPath + "/nix/default.nix") { inherit pkgs versions; lib = pkgs.lib; })
      .packages."${o.name}-src"
  ' >"$4" 2>&1
}

# Rewrites rev/hash of one entry in flake.nix's versions block.
set_pin() { # name tag hash
  python3 - "$@" <<'EOF'
import re, sys
name, rev, hash_ = sys.argv[1:]
src = open("flake.nix").read()
block = re.compile(r'(^\s*' + re.escape(name) + r' = \{\n)(.*?)(^\s*\};)', re.M | re.S)
m = block.search(src)
if not m:
    sys.exit(f"no '{name} = {{' block in flake.nix")
body = re.sub(r'rev = "[^"]*";', f'rev = "{rev}";', m.group(2), count=1)
body = re.sub(r'hash = "[^"]*";', f'hash = "{hash_}";', body, count=1)
open("flake.nix", "w").write(src[:m.start(2)] + body + src[m.end(2):])
EOF
}

open_pr() { # group tag ; uses arrays OLD/HASH filled by the caller
  local group=$1 tag=$2 slug branch name links="" files=""
  slug=${group// /+}
  branch="upstream/${slug}-${tag}"
  if git ls-remote --exit-code --heads origin "$branch" >/dev/null; then
    echo "  PR branch $branch already exists, skipping"; return
  fi
  git switch -q -c "$branch"
  for name in $group; do
    set_pin "$name" "$tag" "${HASH[$name]}"
    links+="- [\`$(field "$name" owner)/$(field "$name" repo)\` ${OLD[$name]}...$tag](https://github.com/$(field "$name" owner)/$(field "$name" repo)/compare/${OLD[$name]}...$tag)"$'\n'
    files+="- \`$name\`: $(grep '^+++ b/' "nix/patches/$name-mtls.patch" | sed 's#^+++ b/##; s/\t.*//' | sed 's/.*/`&`/' | paste -sd, - | sed 's/,/, /g')"$'\n'
  done
  git commit -qam "Bump ${group// / + } to $tag"
  git push -q origin "$branch"
  gh pr create --head "$branch" --title "Bump ${group// / + } to $tag" --body "$(cat <<EOF
Upstream released **$tag**, and the mTLS patch applies to it. This was opened automatically by the weekly upstream check.

"Applies" only means every hunk found its place. It does not mean the code is still right.

**Upstream changes**
$links
**Files the patch touches** (read the upstream changes to these first)
$files
**Before merging**
- [ ] Read the upstream diff for the files above
- [ ] Have the TLS changes reviewed (CLAUDE.md)
- [ ] Build locally and test against your server, once with the client cert and once without (must be refused)

Nothing builds on this PR. Merging pushes to \`main\`, which builds and publishes a release.
EOF
)"
  git switch -q -
}

open_issue() { # group tag log
  local group=$1 tag=$2 log=$3 title
  title="${group// / + } $tag: mTLS patch no longer applies"
  if gh issue list --state open --limit 100 --json title --jq '.[].title' | grep -Fxq "$title"; then
    echo "  issue already open, skipping"; return
  fi
  gh issue create --title "$title" --body "$(cat <<EOF
Upstream released **$tag**, and the mTLS patch no longer applies to it. Found by the weekly upstream check.

To fix it, follow "Bumping a version" in CLAUDE.md: reconcile only the rejected hunk, then regenerate the patch as \`git diff $tag..<result>\` over the same files.

<details><summary>Build log (last 150 lines)</summary>

\`\`\`
$(tail -n 150 "$log")
\`\`\`
</details>
EOF
)"
}

if [ "$OPEN_GITHUB" = 1 ]; then
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
fi

status=0
for group in "${GROUPS_[@]}"; do
  read -r first _ <<<"$group"
  declare -A OLD=() HASH=()
  tag=$(newest_common_tag $group)
  for name in $group; do OLD[$name]=$(field "$name" rev); done

  if [ -z "$tag" ] || [ "$tag" = "${OLD[$first]}" ] \
     || [ "$(printf '%s\n%s\n' "${OLD[$first]}" "$tag" | sort -V | tail -1)" != "$tag" ]; then
    echo "$group: up to date (${OLD[$first]})"
    continue
  fi

  ok=1 faillog=""
  for name in $group; do
    HASH[$name]=$(prefetch "$(field "$name" owner)" "$(field "$name" repo)" "$tag")
    log="$LOGDIR/$name.log"
    if ! try_patch "$name" "$tag" "${HASH[$name]}" "$log"; then
      ok=0 faillog=$log
      break
    fi
  done

  if [ "$ok" = 1 ]; then
    echo "$group: ${OLD[$first]} -> $tag, patch applies"
    [ "$OPEN_GITHUB" = 1 ] && open_pr "$group" "$tag"
  else
    echo "$group: ${OLD[$first]} -> $tag, PATCH FAILS"
    tail -n 30 "$faillog" | sed 's/^/    /'
    [ "$OPEN_GITHUB" = 1 ] && open_issue "$group" "$tag" "$faillog"
    status=1
  fi
done

# Locally, a non-zero exit means "some patch needs work". In CI the issue is
# the signal, so the run itself stays green.
[ "$OPEN_GITHUB" = 1 ] && exit 0
exit "$status"
