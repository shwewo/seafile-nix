# Maintaining seafile-nix

This is a practical guide for keeping the mTLS patches alive across upstream releases,
written for someone who doesn't write C. CLAUDE.md has the rules; this file has the how.

## How the mTLS support fits together

You don't need to read the code, but knowing the moving parts tells you which conflicts
matter.

```
 Desktop (Seafile / SeaDrive)

   GUI (C++/Qt)                                  daemon (C)
   seafile-client / seadrive-gui                 seafile / seadrive-fuse
   ┌───────────────────────────┐   writes        ┌──────────────────────────────┐
   │ login dialog: cert picker │ ─────────────▶  │ reads client-ssl-certs.json  │
   │ saves cert per account    │  client-ssl-    │ file sync (libcurl): adds    │
   │ uses it for its own       │  certs.json     │   the cert per server host   │
   │   login/API requests      │ (per host)      │ notifications (websocket):   │
   └───────────────────────────┘                 │   adds the cert per host     │
                                                 └──────────────────────────────┘
 Android (seadroid, Java): one self-contained patch, with no daemon.
```

So each component has a few **hooks**: small edits inside upstream's own functions that
call into mTLS code. Conflicts almost always happen at those hooks. The bulk of the logic
sits in files or blocks that are entirely ours, so it rarely conflicts.

## What each patch touches

The "risk" column says how likely a conflict in that file is to need real thought.

### seafile (core daemon, C). Highest risk.
| File | What the patch does there | Risk |
|---|---|---|
| `daemon/http-tx-mgr.c` | Loads `client-ssl-certs.json`, and before every HTTP request tells libcurl which cert to present for that host (PEM or .p12). | medium: a one-line `load_client_cert (curl, url);` hook in `http_get`/`http_put`/`http_post` |
| `daemon/http-tx-mgr.h` | Declares `http_tx_manager_get_client_cert()`. | low |
| `daemon/notif-mgr.c` | Adds the cert to the notification websocket (libwebsockets). For `.p12` it builds an OpenSSL `SSL_CTX` by hand and must free it when the connection is rebuilt. | **high**: upstream rewrote this file in v9.0.21 |
| `daemon/seafile-config.h`, `seafile-session.c/.h` | A host-independent fallback cert from config or `SEAFILE_CLIENT_SSL_*` environment variables. | low |

### seafile-client (Qt GUI, C++). Medium risk.
| File | What the patch does there | Risk |
|---|---|---|
| `src/ui/login-dialog.cpp/.h` | The "client certificate" checkbox and file pickers on the login form. | medium: upstream edits the login form often |
| `src/account-mgr.cpp/.h`, `src/account.h` | Saves the cert with the account, copies the cert file into Seafile's data dir, writes `client-ssl-certs.json`. | medium |
| `src/api/api-client.cpp` | Presents the cert on the GUI's own API requests. | low |
| `src/shib/shib-login-dialog.cpp` | Presents the cert in the SSO web view. | low |
| `src/settings-mgr.cpp/.h`, `CMakeLists.txt` | Adds a `BUILD_CLIENT_SSO_SUPPORT` build option (SSO without the embedded browser) and renames the matching `#ifdef`s. | low, mechanical |
| `src/utils/mtls.cpp/.h` | New files, all ours. | none |

### seadrive-gui (Qt GUI, C++). Medium risk.
Same shape as seafile-client: `login-dialog`, `account-mgr`, `account.h`, `api-client.cpp`,
new `utils/mtls.cpp/.h`. Note that its `seadrive-gui.cpp` hunk is *not* mTLS: it only
changes a `connect(...SIGNAL/SLOT...)` call to the newer `&QTimer::timeout` syntax. It
predates this guide. If it ever conflicts, try dropping it and see whether the build still
works. The cert is stored in QSettings
under the account's server URL. Since v3.0.27 upstream normalizes that URL in
`enableAccount`, so the save must use `new_account`.

### seadrive-fuse (SeaDrive daemon, C). Medium risk.
The same three changes as seafile core (`http-tx-mgr.c/.h`, `notif-mgr.c`), on an older copy
of that code. Upstream tends to port core's `notif-mgr.c` changes here later, so expect
the same conflict seafile had in v9.0.21 when it does.

### seadroid (Android, Java). Low to medium risk.
New files `ssl/ClientCertManager.java` and `ssl/ClientCertKeyManager.java` hold the logic.
Hooks sit in `UnsafeOkHttpClient.java` (the HTTP client), the login and SSO activities, and
the account screens. Java conflicts are much easier to reason about than C ones.

## Bumping a component

You usually don't need to look for new tags yourself. Every Monday the `Upstream check`
workflow runs `check-bump.sh` on every component at upstream's latest tag:

- The patch applies: it opens a PR with the new pin. Review it and run the test checklist
  before merging. Nothing builds on that PR, and merging publishes a release.
- The patch doesn't apply: it opens an issue with the `check-bump.sh` output. Leave the issue
  open until you do the bump. A closed issue is opened again the next week.

`seafile` and `seafile-client` are only bumped together. To see what it would do, without
changing anything:

```bash
scripts/weekly-bump.sh
```

To check or bump one component by hand:

```bash
scripts/check-bump.sh seadrive-gui            # latest tag
scripts/check-bump.sh seadrive-gui v3.0.28    # specific tag
```

**If it says OK**, write the pin and build:

```bash
scripts/check-bump.sh seadrive-gui v3.0.28 --update
```

```bash
nix build .#seadrive-gui
```

Then run the test checklist below and commit.

**If hunks are rejected**, the script lists each one:

- `[moved]`: upstream code is still there, just shifted. Open the `.rej` file, find the same
  spot in the real file, and paste in the `+` lines (without the `+`). Delete the `.rej`.
- `[NEEDS REVIEW]`: upstream changed the lines the patch edits. Read the upstream diff for
  that file to see *why* it changed:

  ```bash
  git -C <work-tree> fetch --depth 50 origin tag <old-tag>
  ```

  ```bash
  git -C <work-tree> diff <old-tag> <new-tag> -- <file>
  ```

  Often it's still simple (a variable renamed, a line moved into a helper). If upstream
  restructured the function, and especially in C, get help (below).

When no `.rej` files are left:

```bash
scripts/check-bump.sh regen seadrive-gui /tmp/check-bump-seadrive-gui-XXXX/src
```

```bash
scripts/check-bump.sh seadrive-gui v3.0.28 --update
```

Rules (from CLAUDE.md): pin tags, never branches. Bump `seafile` and `seafile-client`
together. Put only mTLS changes in the patch, so don't "fix" unrelated upstream code
while you're in there.

### Getting help with a C/C++ conflict

Give a helper (a person, or an AI session in this repo) all of:
1. the `.rej` file,
2. the upstream diff for that file between the old and new tag (command above),
3. the matching section of "What each patch touches" above.

Ask them to keep the mTLS behavior identical and to say explicitly who frees any memory
the patch allocates. That's the classic C mistake, and the one that bit `notif-mgr.c`
(an `SSL_CTX` leaked on every reconnect until it was freed in `reset_lws_context`).

Then still have someone else look at it. A build that passes doesn't prove C is correct.

## Test checklist (after every bump)

A green build only proves it compiles. You need a server that **requires** a client
certificate, for example nginx in front of Seafile:

```nginx
ssl_client_certificate /etc/nginx/client-ca.pem;
ssl_verify_client on;
```

Also proxy the notification endpoint (`/notification`) through the same nginx, or the
websocket check below tests nothing.

For each platform you ship (Linux AppImage, macOS .pkg, Android APK):

- [ ] Login **without** a cert fails (proves the server really enforces mTLS).
- [ ] Login with a **PEM** cert + key works.
- [ ] Login with a **.p12** bundle works (Android: also a KeyChain cert).
- [ ] A library syncs both ways (upload and download): this tests the daemon's libcurl path.
- [ ] Desktop: `seafile.log` (or `seadrive.log`) shows
      `Successfully connected to notification server`, and changes made in the web UI show up
      within seconds, without waiting for the periodic sync.
- [ ] Restart the app: still logged in, still syncing, no cert re-prompt.
- [ ] SSO login (if you use it) works with the cert.

## Things that are not mTLS but still need care

- **`nix/fuse2/`**: nixpkgs dropped fuse2 and seadrive-fuse still needs it. Delete this
  directory once upstream seadrive-fuse supports fuse3 (look for `FUSE_USE_VERSION 3x`).
- **nixpkgs bumps** (`nix flake update`) can break builds independently of Seafile. Bump
  nixpkgs in its own commit, so you know which change broke what.
- **seadroid release builds** use R8 minification. If the cert picker or handshake breaks
  only in release builds, R8 probably stripped something and needs a `-keep` rule.
