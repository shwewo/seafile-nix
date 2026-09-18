# seafile-nix

Builds Seafile + SeaDrive (Linux, macOS) and the Seafile Android client, all with mutual TLS
(client certificate) support added on top of upstream. This is the **only** place that mTLS
support lives — there are no forks anymore. Read this before touching `flake.nix`,
`nix/default.nix`, `nix/android.nix`, or anything under `nix/patches/`.

## The model: pristine upstream + a small patch, nothing else

Previously this project worked by forking `haiwen/seafile`, `seafile-client`, `seadrive-fuse`,
and `seadrive-gui` on GitHub (as `shwewo/*`), committing mTLS support directly to `master`, and
periodically merging upstream `master` back in — without fetching upstream tags first, and
without close review of LLM-resolved merge conflicts in security-relevant TLS/cert code. That
produced forks with version/tag info out of sync with reality, and no reliable way to know
whether a conflict resolution had silently broken something in code nobody on this project reads
closely (C/C++, Kotlin).

That's gone. As of the September 2026 rewrite:

- **Sources are pristine upstream**, fetched via `pkgs.fetchFromGitHub` at an exact tag pinned in
  the `versions` block of `flake.nix`.
- **Each component gets exactly one patch file**, `nix/patches/<name>-mtls.patch`, applied on top
  via `pkgs.applyPatches` (`nix/android.nix` does the equivalent for the one component Nix
  doesn't sandbox-build — see below). The patch is scoped to *only* the mTLS-related commits —
  nothing else.
- **The `shwewo/*` fork repos on GitHub are retired.** They still exist but nothing in this
  project reads from them. Don't add them back as flake inputs.
- **`nix/lib.nix` no longer exists.** It used to parse version numbers out of each fork's
  `CMakeLists.txt` and supported a `NIX_SEAFILE_LOCAL=1` sibling-checkout dev workflow for editing
  the forks in place. Both ideas are obsolete now that there's no fork tree to point at — version
  strings are derived directly from the pinned tag (see `versionOf` in `nix/default.nix`).

## Repo layout

```
flake.nix              # inputs (nixpkgs only) + the `versions` pin table + top-level outputs
nix/default.nix         # fetchFromGitHub + applyPatches per component; wires components/linux/darwin/android together
nix/components.nix       # seafile-shared (seaf-daemon) and seafile-client (Qt) derivations
nix/linux.nix            # AppDir/AppImage bundling for Seafile + SeaDrive
nix/darwin.nix           # .app bundle + aarch64 .dmg disk image
nix/android.nix          # Android SDK/NDK/CMake toolchain + patched seadroid source (dev shell, not a nix build)
nix/patches/*.patch      # one patch per component, mTLS-only
.github/workflows/build.yml  # CI: builds everything, publishes one GitHub release per push to main
```

## The `versions` pin table (`flake.nix`)

This is the only place version numbers live. Each entry is `{ owner, repo, rev, hash }` for
`fetchFromGitHub`. `rev` is a tag (e.g. `"v9.0.20"`), not a branch — pulling from a moving branch
is exactly the mistake that caused the original mess.

Current pins (September 2026) and why they're not all "latest":

- **`seafile` → `v9.0.20`**, **`seafile-client` → `v9.0.20`** (deliberately matched, *not*
  `seafile-client`'s true latest `v9.0.21`). `seafile-client` v9.0.21 references a libseafile
  constant (`SYNC_ERROR_ID_WATCH_FAILED`) that only exists in `seafile` core v9.0.21, not v9.0.20,
  so bumping the client alone breaks the build with an undeclared-symbol error. Bumping core to
  v9.0.21 too would require reconciling the mTLS patch against a ~130-line upstream rewrite of
  `daemon/notif-mgr.c` (proxy/reconnect logic) — exactly the kind of unreviewed change to TLS-
  adjacent networking code this rewrite exists to avoid. If you need to move past v9.0.20, expect
  to do that reconciliation by hand (see "Bumping a version" below), and bump both repos together.
- **`seadrive-fuse` → `v3.0.26`** (latest at time of writing) — confirmed upstream didn't touch
  the mTLS-patched files (`http-tx-mgr.{c,h}`, `notif-mgr.c`) between v3.0.24 and v3.0.26, so this
  one *could* track latest with a clean patch.
- **`seadrive-gui` → `v3.0.22`** — the original fork was a single squashed commit at this version
  with no history, so this is the only version the patch was ever actually verified against.
  Bumping it means hand-diffing against the new tag (see below), not just re-running `git diff`.
- **`seadroid` → `v4.0.13`** (latest at time of writing).

## How the patches were built (for context, not something you need to redo)

For `seafile`, `seafile-client`, `seadrive-fuse`, and `seadroid`, the forks had real git history,
so each patch is `git diff <pinned-tag>..<last-mtls-commit-or-HEAD>` restricted to exactly the
files the mTLS commits touched — verified file-by-file that no *other* (non-mTLS) commit touched
the same files in that range, so nothing except the mTLS work is in the patch.

One thing worth knowing if you ever redo this kind of extraction: **check commit authorship
carefully, including local/placeholder git identities**, not just the obvious `<you>@gmail.com`.
The `seadroid` fork had three mTLS commits authored under `cunt@debian13-...localdomain` (a
machine-default git identity from before the fork's author configured `user.email` properly) that
a plain `--author=` filter would have silently missed and left orphaned in "not yet upstream, and
now unpatched" limbo.

Also worth knowing: at the time of extraction, upstream `seadroid` had *independently* fixed the
`uuid@auth.local`-instead-of-`contact_email` bug that one of the fork's own commits also fixed.
That fix was **dropped** from the patch (not included) because upstream already has it —
duplicating it would just be dead code at best, a conflict at worst. If you're ever redoing this
kind of extraction elsewhere, always diff against the target pin first and let already-upstreamed
fixes cancel out of the diff naturally, rather than blindly replaying every historical commit.

For `seadrive-gui` (no usable git history — single squashed commit), the patch was built by
diffing the pristine upstream tree at v3.0.22 against the fork's working tree directly, file by
file, and **excluding** two dead files found in that process that weren't referenced by
`CMakeLists.txt` (a stray root-level `account-mgr.cpp` and a stray `src/login-dialog.cpp` —
leftover duplicates from whatever produced the squashed commit, not part of the actual build).

## Android: why it's not a `nix build`

Every other component here is a fully sandboxed, hermetic `nix build` — no network during the
build, byte-for-byte reproducible. Android can't be, because Gradle resolves its own dependencies
from Maven/Google's repos at build time, and the Nix sandbox blocks network access during a build.
Doing this properly (fully pinned Gradle dependencies via a lockfile + Nix fetcher) is a bigger
lift than this rewrite covers.

Instead, `nix/android.nix` provisions a **reproducible JDK 17 + Android SDK (platform 36,
build-tools 35.0.0, NDK 27.0.12077973, CMake 3.22.1) as a dev shell** — `nix develop .#android` —
and Gradle runs inside it with normal network access. The NDK and CMake versions aren't optional
extras: AGP needs them to strip `.so` files from a couple of dependency AARs (there's a small
amount of native code in `seadroid`, a HEIC/motion-photo encoder under `app/src/main/cpp/`) even
though `seadroid` itself declares no `ndkVersion`. If you bump the `seadroid` pin and the build
starts asking to auto-install a different NDK/CMake version into the (read-only) Nix store SDK,
bump the version in `nix/android.nix` to match rather than trying to work around it.

Signing: `app/build.gradle`'s `release` signing config unconditionally loads `app/key.properties`
at Gradle *configuration* time (not just when building `assembleRelease`) — so even
`assembleDebug` fails without it. CI (`.github/workflows/build.yml`, `android` job) handles this
by writing a real `key.properties` from the `ANDROID_KEYSTORE_BASE64` /
`ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD` repo secrets if they're
set, and building `assembleRelease`; otherwise it generates a throwaway keystore on the runner and
builds `assembleDebug`, publishing an unsigned build clearly labeled as such in the release notes.
See `README.md`'s Android section for the `keytool` command to generate a real release key.

This whole pipeline (source fetch + patch apply + Gradle build) was run and verified by hand
during the September 2026 rewrite: `./gradlew assembleDebug` succeeded end-to-end and produced a
working APK.

## Bumping a version

1. Edit `rev` for the component in `versions` (`flake.nix`). Use a tag, not a branch.
2. `nix build .#<something-that-depends-on-it>` — it'll fail with the correct `hash` to paste in
   (or prefetch it yourself: `nix flake prefetch --json github:<owner>/<repo>/<tag>`).
3. If `nix/patches/<name>-mtls.patch` still applies cleanly, you're done.
4. If it doesn't: `pkgs.applyPatches` fails and names the rejected hunk (or, if you're testing by
   hand, `git apply` leaves a `.rej` file or `<<<<<<<` conflict markers). **Only look at that
   hunk** — a handful of lines of context around the conflict — and reconcile it with the new
   upstream code. Don't reread the whole file or the rest of the codebase to do this. For the
   C/C++ patches especially (TLS/cert-handling code), get a second pair of eyes on the
   reconciliation before shipping it — that's the whole reason this rewrite happened.
5. For `seadroid`, also check whether the NDK/CMake versions in `nix/android.nix` still match what
   AGP wants (see above) — a compileSdk bump can pull in a newer NDK requirement.
6. Regenerate the patch file itself with a clean two-point `git diff` (pinned-tag → your
   reconciled result) restricted to the same file list as before, so the patch stays scoped to
   only the mTLS change and doesn't pick up unrelated upstream drift.

## Things to *not* do

- Don't add `shwewo/seafile`, `shwewo/seafile-client`, `shwewo/seadrive-fuse`, or
  `shwewo/seadrive-gui` back as flake inputs. They're retired.
- Don't pin `rev` to a branch (e.g. `master`) instead of a tag. That's the original mistake.
- Don't let a patch-application failure turn into "just regenerate the whole patch from the
  current fork state" — there is no fork state anymore. Reconcile the failing hunk against the
  new upstream tag directly.
- Don't expand `nix/patches/*.patch` to include anything beyond the mTLS change (formatting
  drift, unrelated fixes, etc.) when regenerating after a bump — keep them scoped, the same way
  they were extracted originally.
