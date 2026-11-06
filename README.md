# Kitty Finder

Your cloud drives in Finder, without filling up your Mac. Files show up like
normal files but download only when you open them. Downloaded copies are kept
up to a limit you choose (10 GB by default), and the ones you haven't used for
longest are cleared automatically. Everything stays in the cloud.

Phase 0 supports Google Drive, with any number of accounts.

## Install (for friends)

1. Unzip `KittyFinder-0.1.0.zip` and drag **Kitty Finder** into **Applications**.
2. Open it. macOS will say it can't check the app for malware, because it
   isn't signed by an Apple developer account yet. Click **Done**, then open
   **System Settings → Privacy & Security**, scroll down and click
   **Open Anyway** next to Kitty Finder.
3. A window opens (the kitty icon also sits in the menu bar, near the clock).
   Click **Add Google Drive…** and sign in.
   If Google says the app isn't verified, click **Advanced → Go to Kitty Finder**.
4. Your drive appears in Finder under `~/Kitty Finder`, and under Locations in the
   sidebar.

After an update, macOS may ask once whether Kitty Finder can use its keychain item.
Click **Always Allow**.

## How it works

Kitty Finder is a menu bar app that runs a bundled, patched copy of
[rclone](https://rclone.org) (MIT licence) for each account:

- `rclone nfsmount` serves the drive to Finder through macOS's built-in NFS
  client, so nothing extra needs installing (no macFUSE, no admin password).
- `--vfs-cache-mode full` downloads only the parts of files that are read,
  keeps edits on disk until they've uploaded, and evicts least-recently-used
  copies above the limit.
- `-o locallocks` is required: rclone's NFS server has no lock manager, and
  without local locking macOS can't store extended attributes, so Finder
  copies fail with "Operation not permitted".
- The patch (`patches/rclone/`) adds `--nfs-apple-meta-dir`, which keeps
  macOS `._*` (AppleDouble) and `.DS_Store` files on the Mac instead of
  uploading them next to every file in Drive.

State on disk:

| What | Where |
|---|---|
| Accounts and settings | `~/Library/Application Support/Kitty Finder/*.json` |
| rclone config (encrypted, password in the login keychain) | `~/Library/Application Support/Kitty Finder/rclone.conf` |
| Downloaded copies and pending uploads | `~/Library/Application Support/Kitty Finder/cache/<id>` |
| Local-only Finder metadata | `~/Library/Application Support/Kitty Finder/meta/<id>` |
| Drives | `~/Kitty Finder/Google Drive (<email>)` |
| Logs | `~/Library/Logs/Kitty Finder` |

## Build

Needs the Xcode Command Line Tools (full Xcode isn't required) and Go (`brew install go`).

```bash
scripts/build-rclone.sh   # clone rclone v1.75.2, apply patches, build universal binary
scripts/test.sh           # unit tests
scripts/bundle.sh         # build/Kitty Finder.app
scripts/package.sh        # dist/KittyFinder-<version>.zip
```

### Google sign-in client

rclone's shared Google client is being retired, so Kitty Finder needs its own.
See [docs/google-setup.md](docs/google-setup.md). Put the client in
`Config/GoogleOAuth.plist` (git-ignored) to build it into the app, or paste it
into **Settings → Google**.

## Spike

`spike/` holds the scripts that validated the approach on macOS 26:
`full-local.sh` (writes, Finder-style copies, metadata, cache eviction,
partial reads, crash recovery) against a local fake remote, and
`spike-tests.sh <mount> rclone:<remote>:` for a real cloud remote.
