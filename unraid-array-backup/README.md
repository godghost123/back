# ArrayBackup – unRAID plugin

Backs up **all data disks of the unRAID array in parallel** (one `rsync` job
per disk) and writes the streams **aggregated onto a fast, locally attached
target** (e.g. a RAID0 of NVMe/SSDs). Every completed run is a **complete
snapshot of the whole array** – space-efficient via hard links
(`rsync --link-dest`, same idea as Time Machine).

Parity disks are skipped automatically (they are not mounted under `/mnt` and
can be rebuilt from the data disks).

## Features

- **Parallel reads, aggregated writes:** all data disks are read at the same
  time; the write streams saturate the RAID0 target
- **Array snapshots:** each run looks like a full copy of the array
  (`runs/<timestamp>/disk1 … diskN`)
- **Disk history:** per-disk chronological chain
  (`perdisk/diskN/<timestamp>` as symlinks)
- **Space-efficient:** unchanged files are hard links into the previous run
- **Atomic promotion:** unfinished runs live in a hidden `.ab-staging/` area on
  the target; only a completed run is renamed (same filesystem, atomic) into
  `runs/` and the `latest` symlink is flipped. An aborted run never appears as
  an apparently complete snapshot, and `--delete` never runs against a visible
  snapshot of a previous generation
- **Staged (Etappen) operation:** a stopped or crashed run resumes on the next
  start; `rsync --partial-dir=.rsync-partial` makes already-copied files
  reusable while keeping truncated files out of the snapshot. The first run
  therefore becomes a full backup even across many sessions
- **Retries:** transient rsync failures (exit 10/11/12/30) are retried up to 3
  times with backoff; fatal errors (1/2/3/4) stop immediately. The failure
  reason is surfaced in the WebUI (status JSON is built with `json_encode` and
  validated before writing)
- **Retention:** keeps the last N runs, enforces a minimum free space guard,
  individual runs can be pinned
- **WebUI** under Settings: live progress per disk, snapshot table, paged array
  browser (500 entries + "load more"), disk history, configuration. All labels
  come from a single string table (`de`/`en`) in `ArrayBackup.page`
- **Scheduler:** cron entry on flash
  (`/boot/config/plugins/arraybackup/arraybackup.cron`), re-activated via
  `update_cron` on every boot
- **Safety:** lock file against double starts, self-backup protection (target
  on the array is refused), filesystem check (hard links required), free space
  check, dry-run mode, path traversal protection in the browser API, strict
  run-id validation for pin/delete

## Requirements

- unRAID 6.12+ (6.10/6.11 usually work as well)
- Backup target mounted **locally** on the server (e.g. `/mnt/backup`),
  filesystem **ext4/xfs/btrfs** (hard links required; FAT/exFAT is rejected)
- `rsync` ships with unRAID; `php`/`flock`/`findmnt` are part of unRAID

## Installation

> **Important:** earlier failed install attempts leave old `.plg` copies in
> `/boot/config/plugins-error/` (WebUI: Plugins → tab "Plugin File Install
> Errors"). **Delete them there**, otherwise they are re-installed on every
> boot and may fail again. Also remove an old
> `/boot/config/plugins/arraybackup.plg` before installing the new one.

Local install (no GitHub repo):

1. Copy `arraybackup.plg` to the USB flash stick, e.g.
   `/boot/config/plugins/arraybackup.plg` (SMB share `\\server\boot\config\plugins\`).
2. WebUI → **Plugins**: the file is installed automatically on the next boot,
   or immediately via the "Install Plugin" box with the path
   `/boot/config/plugins/arraybackup.plg` (enable "Force Break" if the same
   version is already listed). Console alternative:
   `plugin install /boot/config/plugins/arraybackup.plg`
3. Reload the WebUI → **Settings → ArrayBackup** appears in the menu.
4. Tab **Configuration**: enter the target mountpoint (e.g. `/mnt/backup`), save.
5. First time: enable **dry run** and click "Start backup", then turn dry run
   off and start a real run.

### Auto-update via GitHub

`build.sh` sets `pluginURL` to
`https://raw.githubusercontent.com/godghost123/back/main/unraid-array-backup/arraybackup.plg`.
For "Check for Updates" in WebUI → Plugins to work, the GitHub repo must be
**public** (private repos return 404 on raw.githubusercontent.com – the update
check then finds nothing and "nothing happens").

After making it public (or after changing the URL in `build.sh`): **remove and
re-install the plugin once** so the copy stored on flash
(`/boot/config/plugins/arraybackup.plg`) picks up the new `pluginURL`.
From then on, Plugins → ArrayBackup → "Check for Updates" is enough.

### Update / re-install

The plugin manager only overwrites existing files when their SHA256 in the PLG
does not match – covered by the generated `<SHA256>` blocks. While developing,
this additionally helps:

```bash
rm -rf /usr/local/emhttp/plugins/arraybackup   # tmpfs, a reboot also does it
plugin install /boot/config/plugins/arraybackup.plg
```

Building from source (Linux/macOS/Git-Bash):

```bash
./build.sh   # regenerates arraybackup.plg, then validates it
```

`build.sh` stamps `VERSION` (override with `VERSION=... ./build.sh`), embeds
all `src/` payloads base64-encoded with `<SHA256>` blocks, and finally runs
`tools/validate_plg.py` as a build gate – the build fails if the generated PLG
does not parse or any base64/SHA256 mismatches.

## Target layout

```
/mnt/backup/
├── .ab-staging/               # hidden; unfinished runs only (resume lives here)
│   └── r-20261103-020000/     # being copied right now / resumable after abort
├── runs/
│   └── r-20261103-020000/
│       ├── .runmeta.json      # state, exit codes, logical & delta size per disk
│       ├── .pinned            # only when the run is pinned
│       ├── disk1/  disk2/ …   # full-array view
├── latest -> runs/r-…         # last successful run
└── perdisk/
    └── disk1/r-… -> ../../runs/r-…/disk1   # disk history (symlinks)
```

Promotion is: stage in `.ab-staging/` → copy → write `.runmeta.json` →
same-FS `mv` into `runs/` → flip `latest`/`perdisk` symlinks → prune. If the
`mv` fails, the run is marked failed and nothing in `runs/` changes.

## How it works

1. Engine validates: array running, target mounted, target not on the array
   itself, filesystem supports hard links, enough free space.
2. A staged run directory `.ab-staging/r-<YYYYMMDD-HHMMSS>/` is created (or an
   interrupted one is reused when resume is enabled).
3. Per data disk, one
   `rsync -aHAX --numeric-ids --delete-delay --partial-dir=.rsync-partial --link-dest=<last successful run>/<disk>`
   runs concurrently (`max_jobs` caps concurrency, `bwlimit` throttles).
   `--link-dest` hard-links unchanged files; `--delete-delay` only removes
   orphans after the transfer, never mid-way.
4. Transient rsync errors (10/11/12/30) retry up to 3 times with backoff;
   exit 24 (vanished source files) counts as success; fatal codes abort.
5. On success: `.runmeta.json` written, run atomically renamed into `runs/`,
   `latest` and `perdisk/` updated, retention applied (count + free-space
   guard, pinned runs kept).
6. Live progress lives in `/var/run/arraybackup/status.json` (RAM); run
   summaries in `/boot/config/plugins/arraybackup/logs/` (flash-friendly,
   rotated at 1 MB).

## Test plan

| Scenario | Steps | Expectation |
|---|---|---|
| Dry run | enable dry run, start | rsync `-n`, **no** run directory left in `runs/` or `.ab-staging/` |
| Snapshot chain | 2 runs, then `stat runs/r-*/disk1/<same file>` | same inode = hard link, delta size ≈ changes only |
| Abort | press "Stop" during a run | state `aborted`, work stays in `.ab-staging/`, next `--link-dest` is still the last `success` |
| Resume | start again after abort | staged run continues, already-copied files skipped (fast start, small delta) |
| Resume off | disable "resume", start | staged leftovers are dropped, a fresh run begins |
| Double start | start during a run | second engine exits immediately with the lock message |
| Retention | `retention_runs=3`, 5 runs, pin one | exactly 3 unpinned kept, pinned survives, `latest`/`perdisk` consistent |
| Self-backup | point target at `/mnt/disk1` | save is rejected in the WebUI; the engine also refuses |

## Files

| File | Purpose |
|---|---|
| `arraybackup.plg` | finished plugin manifest (generated, checked in – it is what `pluginURL` serves) |
| `build.sh` | generates the `.plg` from `src/` and runs the validator as a gate |
| `tools/validate_plg.py` | verifies the PLG: XML parses, base64 decodes, SHA256 matches, no CRLF/BOM |
| `src/ArrayBackup.page` | WebUI with `.page` header (`Menu="Settings"`); tabs: Backups, Array browser, Disk history, Configuration; single de/en string table |
| `src/install.sh` | post-install script (directories, default config, cron on flash) |
| `src/include/ajax.php` | JSON API (`config-get/-save`, `start`, `stop`, `status`, `runs`, `ls` [paged], `pin`, `delete-run`) |
| `src/include/engine.sh` | backup engine (parallel rsync, staging + atomic promotion, retries, retention, log rotation) |

## Known limits / future ideas

- v1 mirrors **disks**, not shares (a share union view is conceivable)
- no checksum verification, no notifications
- retention by count, not a GFS scheme
