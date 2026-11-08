# Kitty Finder (formerly KittyDock) — Phase 0 (free, rclone-based)


## Step 1 — Spike (go/no-go gate)
- [x] Fetch official rclone, verify SHA256 (v1.75.2)
- [x] `rclone nfsmount` as normal user (no sudo, no macFUSE)
- [x] Browse, read, create, edit, atomic save, rename, move, delete, seek-write → synced
- [x] Finder-style copies (`cp`, `ditto`, xattrs): fixed with `-o locallocks` + rclone patch
- [x] No `._*` / `.DS_Store` reach the remote (patch: `--nfs-apple-meta-dir`)
- [x] Partial reads download only what's read (1 MiB read → ~2 MiB cached of 120 MiB)
- [x] Cache cap eviction (150M cap: 241M peak → 120M)
- [x] Crash recovery: kill -9 → force unmount → restart → pending upload finished
- [x] Clean unmount on SIGTERM
- [x] Real Google Drive via the app's own mount (spike/real-drive.sh): 16/16 pass, no `._`/`.DS_Store`
      in Drive, 0 pending uploads, 0 errored files, test folder removed (to Drive trash)
- [ ] Manual in Finder: Quick Look, TextEdit/Preview save, drag-copy, sleep/wake, offline
- [x] Decision: **GO** with patched rclone nfsmount

## Step 2 — App skeleton (SwiftPM; Xcode not needed)
- [x] Package: KittyDockCore (logic) + KittyDock (menu bar app) + tests
- [x] scripts/build-rclone.sh (pinned v1.75.2 + patches → universal binary)
- [x] scripts/bundle.sh (universal .app, ad-hoc signed), scripts/package.sh (zip)
## Step 3 — Accounts & auth
- [x] Encrypted rclone.conf, password in login keychain (verified on launch)
- [x] Google sign-in via `rclone authorize` + own OAuth client; email from Drive API
- [x] Multiple accounts (accounts.json); add / disconnect / remove
## Step 4 — Mount manager
- [x] One supervised nfsmount per account, rc stats (env creds), restart w/ backoff
- [x] Wake → health check; eject in Finder → "paused"; stale engines cleaned on launch
## Step 5 — Settings
- [x] Cache limit (split across accounts), launch at login, Free Up Space (refuses if unuploaded)
- [x] Google client override
## Step 6 — Package for friends
- [x] README install steps
- [ ] Build with bundled Google client and share zip

## Review
### Spike run 1 (stock rclone)
- Finder-style copies failed with EPERM. Root cause: rclone's NFS server has no NLM lock
  manager; macOS locks the AppleDouble `._` file it uses to store xattrs, the lock fails, and the
  kernel deletes the file and returns EPERM. `-o locallocks` fixes it (nfsmount forwards `-o`).
- With locking fixed, every file gets a `._name` sidecar uploaded to the cloud. rclone filters
  don't stop VFS uploads, so rclone was patched (user chose this over accepting clutter or FUSE-T).

### Spike run 2 (patched rclone, `patches/rclone/0001-…`)
- New `--nfs-apple-meta-dir`: `._*` and `.DS_Store` live in a local dir, are hidden from listings,
  follow renames and deletes. 5 Go unit tests + all existing rclone NFS tests pass.
- Full local suite passes (spike/full-local.sh), plus real-drive harness self-test (spike/real-drive.sh).

### Findings that changed the plan
- rclone's shared Google client_id is being retired during 2026 → our own OAuth client is required,
  not optional. Built into the app via Config/GoogleOAuth.plist or entered in Settings.
- Config key is `skip_gdocs` (not `drive_skip_gdocs`); `config create` also needs
  `config_refresh_token=false config_change_team_drive=false` to finish non-interactively.
- VFS cache lives in Application Support, not ~/Library/Caches (holds unuploaded edits; Caches is purgeable).
- Command Line Tools have Swift Testing but not XCTest → scripts/test.sh adds framework paths.

### Verified
- 18 Swift unit tests pass (scripts/test.sh).
- App launches: config encrypted (RCLONE_ENCRYPT_V0), keychain item created, ~/KittyDock created.
- The app's exact mount flags: rc works with env credentials, 401 without, SIGTERM unmounts.

### Google setup (2026-11-06)
- Cloud project `kittydock`, Drive API on, consent screen External + **In production** (100-user cap,
  unverified-app screen), scope `auth/drive`, Desktop client "KittyDock Mac".
- Production needed a public home page + privacy policy: site/ deployed to https://kittydock.vercel.app
  (Vercel project `kittydock`), authorized domain kittydock.vercel.app.
- Google shows a client secret once, only until the page reloads; three secrets were lost that way.
  scripts/import-google-secret-from-clipboard.sh / import-google-client.sh move it into
  Config/GoogleOAuth.plist without displaying it.

### Real Drive findings
- Works end to end: sign-in, mount, writes, Finder-style copies, cleanup.
- Browsing a folder of photos in Finder icon/gallery view downloads them for previews
  (13 × .CR3 ≈ 160 MB on first browse). Bounded by the cache limit; list view avoids it.
- rclone logs "failing create to indicate lack of support for 'exclusive' mode" as ERROR: benign.

### Fixed: keychain prompt (2026-11-06)
- Keychain reads/writes now run off the main thread; the window shows "Starting…" with instructions
  while macOS asks (verified: window on screen alongside SecurityAgent, main thread not blocked).
- Deny/cancel on the prompt used to be treated as "key missing" → config moved aside, accounts wiped.
  Now `Keychain.lookup` distinguishes notFound from failed; failure shows Try Again and keeps everything
  (verified by hand: Deny → Try Again → Always Allow → same account, Up to date, no backup files).
- Menu bar icon can be hidden by the notch: app opens a window on first launch and on reopen.
- Still expected: one keychain prompt per new build (ad-hoc signature). Goes away with Developer ID (Phase 1).

### Speed tuning (2026-11-06, spike/bench.py on the real Drive)
- Kept: NFS rsize/wsize 1 MB (local throughput 180→1300 MB/s write), dir-cache 1000h +
  poll 15s + vfs-refresh (freshness 59 s → 35 s), transfers 8 + drive pacer 10 ms/200 + chunk 32M
  (100 small files uploaded 80 s → 35 s).
- Dropped: vfs-read-chunk-streams 8 (first bytes 2.6 s → 7 s); write-back 2 s (no measured gain,
  more cancelled uploads). Large-download throughput varies 36–178 s run to run on this network.
- Inherent: first open of a file ≈1.3 s, delete ≈1 s/file (Google API latency per request).

### Finder integration (2026-11-06, spike/finder-ops.swift)
- Fixed: folder copies with symlinks (--links); Google Docs shown as .webloc links so their folders
  delete; rclone race leaving ghost files after delete/rename mid-upload (patch 0002, with tests that
  fail before the fix); folders with only remote ._/.DS_Store files now delete (patch 0001).
- Fixed: app froze on a dead mount (unmounts off the main thread, time-limited); SIGTERM quit
  deadlock (terminate from inside a main-queue block); stop order now unmount first (umount → -f →
  diskutil), then signal the engine once — clean quit in 0.3 s even with files open.
- Not possible over NFS / Drive: Locked flag (chflags), hard links, RENAME_SWAP.

### Not yet verified
- By hand in Finder: Quick Look, TextEdit/Preview save, drag-copy, sleep/wake, offline.
- Launch at login, a second Mac.

## v0.2.0 — Settings, customization, updates, Keep Offline (2026-11-08)
- [x] Settings window fixed (was empty: SwiftUI form with no height) → toolbar tabs
      General / Drives / Storage / Sync / Google / Updates / About, 640×560
- [x] Custom drive names (Finder folder + volume follow, remount), menu bar icon styles
      (two-tone, outline, cloud), upload counter toggle, show window at launch
- [x] Drives folder location with guard (refuses ~/Library, iCloud Drive, CloudStorage,
      other disks, iCloud-synced folders); move remounts every drive
- [x] Storage: space limit, keep N GB free, clear after N days; Sync: poll 15 s / 1 min / 5 min,
      connect/disconnect all; Google Docs on/off
- [x] Updates: GitHub releases/latest, SHA-256 digest check, codesign + bundle id + version
      check, swap in place, relaunch; daily auto-check
- [x] Notifications: upload problems, offline folder ready, update available
- [x] About: versions, links, Report a Problem (GitHub issue with versions only),
      Copy Diagnostics (redacted), Reset Kitty Finder
- [x] Keep Offline: patch 0003 (pins + offline mode, Go tests), app OfflineSync (manifest,
      3 at a time, free-space check, every 15 min and on reconnect), NWPathMonitor →
      vfs/offline, Finder Services "Keep Offline" / "Stop Keeping Offline"
- [x] Patch 0004: Drive saves root_folder_id, so a drive mounts with no internet
- [x] `--timeout 1m --contimeout 15s`: a request stalled across a Wi-Fi reconnect hung the
      mount for minutes (rclone default idle timeout 5m)

### Review (verified on the real Drive)
- 39 unit tests and the rclone vfs / nfs / drive Go tests pass.
- Settings tabs and icon styles checked by hand; rename and restore; Stop Keeping Offline.
- Offline (Wi-Fi off, scripted): browse/read/5 MB file instant, non-offline file fails in
  0.02 s, **restart while offline mounts in 2 s** with the folder intact, offline edit
  uploaded 13 s after reconnecting. First run failed (no root ID offline) → patch 0004.
- Finder needed a relaunch to show the new Services entries the first time.
- Updater: tested end to end after the v0.2.0 release (an 0.1.9 build updating itself).
