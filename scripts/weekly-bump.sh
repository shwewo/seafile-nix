#!/usr/bin/env bash
# Weekly CI job (.github/workflows/upstream.yml). Runs check-bump.sh on each
# group of components at upstream's latest tag and turns the result into a PR
# (the patch applies) or an issue (it doesn't).
#
#   scripts/weekly-bump.sh                 dry run: say what it would open, change nothing
#   scripts/weekly-bump.sh --open-github   CI: push a branch and open a PR, or open an issue
#
# seafile and seafile-client are only ever bumped together, to the same tag.
# Skips anything that already has an open PR branch or open issue.
set -euo pipefail

cd "$(dirname "$0")/.."

open=false
case "${1:-}" in
  --open-github) open=true ;;
  "") ;;
  *) echo "usage: $0 [--open-github]" >&2; exit 2 ;;
esac

groups=("seafile seafile-client" "seadrive-fuse" "seadrive-gui" "seadroid")

pinned() {
  awk -v c="$1" '$0 ~ "^ *" c " = \\{" { b = 1 } b && /rev = / { gsub(/[";]/, "", $3); print $3; exit }' flake.nix
}

# Tag check-bump.sh checked for <comp>, from its summary table.
checked_tag() { awk -v c="$1" '$1 == c && NF >= 4 { t = $3 } END { print t }' "$2"; }

touched_files() {
  grep '^diff --git ' "nix/patches/$1-mtls.patch" | awk '{ sub(/^b\//, "", $4); printf "%s`%s`", sep, $4; sep = ", " }'
}

open_pr() { # group tag
  local group=$1 tag=$2 title branch name links="" files=""
  title="Bump ${group// / + } to $tag"
  branch="upstream/${group// /+}-$tag"
  if git ls-remote --exit-code --heads origin "$branch" >/dev/null; then
    echo "  branch $branch already exists, skipping"
    git checkout -- flake.nix
    return
  fi
  for name in $group; do
    links+="- [haiwen/$name ${old[$name]}...$tag](https://github.com/haiwen/$name/compare/${old[$name]}...$tag)"$'\n'
    files+="- \`$name\`: $(touched_files "$name")"$'\n'
  done
  git switch -q -c "$branch"
  git commit -q -m "$title" -- flake.nix
  git push -q origin "$branch"
  gh pr create --head "$branch" --title "$title" --body "$(cat <<EOF
Upstream released **$tag**, and \`scripts/check-bump.sh\` says the mTLS patch applies cleanly. Opened by the weekly upstream check.

Applying cleanly only means every hunk found its place. It does not mean the code is still right.

**Upstream changes**
$links
**Files the patch touches** (read upstream's changes to these first)
$files
**Before merging** (see MAINTAINING.md)
- [ ] Read upstream's diff for the files above
- [ ] Get any C/C++ TLS changes reviewed
- [ ] Build locally and run the test checklist in MAINTAINING.md

Nothing builds on this PR. Merging pushes to \`main\`, which builds and publishes a release.
EOF
)"
  git switch -q -
}

open_issue() { # group tag log
  local group=$1 tag=$2 log=$3 title
  title="${group// / + } $tag: mTLS patch no longer applies"
  if gh issue list --state open --limit 100 --json title --jq '.[].title' | grep -Fxq "$title"; then
    echo "  issue already open, skipping"
    return
  fi
  gh issue create --title "$title" --body "$(cat <<EOF
Upstream released **$tag**, and the mTLS patch no longer applies to it. Found by the weekly upstream check.

To fix it, run this locally and follow "Bumping a component" in MAINTAINING.md:

\`\`\`bash
scripts/check-bump.sh $(for n in $group; do printf '%s@%s ' "$n" "$tag"; done)
\`\`\`

<details><summary>check-bump.sh output</summary>

\`\`\`
$(sed 's/\x1b\[[0-9;]*m//g' "$log" | tail -n 200)
\`\`\`
</details>
EOF
)"
}

if $open; then
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
fi

logdir=$(mktemp -d)
trap 'rm -rf "$logdir"' EXIT
errors=0
declare -A old

for group in "${groups[@]}"; do
  read -r first _ <<<"$group"
  log="$logdir/${first}.log"
  old=()
  for name in $group; do old[$name]=$(pinned "$name"); done

  rc=0
  # shellcheck disable=SC2086 # $group is a list of component names
  scripts/check-bump.sh $group --update >"$log" 2>&1 || rc=$?

  tag=$(checked_tag "$first" "$log")
  for name in $group; do
    if [[ "$(checked_tag "$name" "$log")" != "$tag" ]]; then
      echo "$group: upstream tags differ ($(for n in $group; do printf '%s=%s ' "$n" "$(checked_tag "$n" "$log")"; done)), waiting until they match"
      git checkout -- flake.nix
      continue 2
    fi
  done

  if [[ $rc -eq 3 || -z "$tag" ]]; then
    echo "$group: check-bump.sh failed:"
    sed 's/^/    /' "$log"
    git checkout -- flake.nix
    errors=1
  elif [[ $rc -eq 0 ]] && git diff --quiet -- flake.nix; then
    echo "$group: up to date ($tag)"
  elif [[ $rc -eq 0 ]]; then
    echo "$group: ${old[$first]} -> $tag, patch applies"
    if $open; then open_pr "$group" "$tag"; else echo "  would open a PR"; git checkout -- flake.nix; fi
  else
    # One of a coupled pair may have been written; bump nothing.
    git checkout -- flake.nix
    echo "$group: ${old[$first]} -> $tag, patch does NOT apply"
    if $open; then open_issue "$group" "$tag" "$log"; else echo "  would open an issue"; fi
  fi
done

exit "$errors"
