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
3. Reload the WebUI → **User Utilities → ArrayBackup** appears in the icon
   grid below (like User Scripts / Docker Stats), not in Settings.
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
├── .ab-staging/                # hidden; unfinished runs only (resume lives here)
│   └── r-20261103-020000/fs/   # ONE shared tree while copying
├── runs/
│   ├── r-20261103-020000/
│   │   ├── .runmeta.json       # state, exit/delta per source, swept, orphans
│   │   ├── .pinned             # only when the run is pinned
│   │   └── fs/                 # merged view: disks AND pools in one tree
│   └── r-20261101-…/disk1/…    # legacy runs (old per-disk layout) stay
├── latest -> runs/r-…          # last successful run
├── perdisk/
│   └── disk1/r-… -> ../../runs/r-…/fs               # source history
└── pershare/
    └── appdata/r-… -> ../../runs/r-…/fs/appdata     # per-share history
```

Because every source writes into the same `fs/` subtree, the path of a file in
the backup does not depend on which mount it came from: a file the mover moved
(cache → array) between two runs keeps its path and is hard-linked via the one
shared `--link-dest` instead of being transferred again. Promotion is: stage in
`.ab-staging/` → transfers → orphan-sweep → write `.runmeta.json` → same-FS
`mv` into `runs/` → flip `latest`/`perdisk`/`pershare` symlinks → prune. If the
`mv` fails, the run is marked failed and nothing in `runs/` changes.

Promotion is: stage in `.ab-staging/` → copy → write `.runmeta.json` →
same-FS `mv` into `runs/` → flip `latest`/`perdisk` symlinks → prune. If the
`mv` fails, the run is marked failed and nothing in `runs/` changes.

## How it works

1. Engine validates: array running, target mounted, target not on the array
   itself, filesystem supports hard links, enough free space.
2. A staged run directory `.ab-staging/r-<YYYYMMDD-HHMMSS>/` is created (or an
   interrupted one is reused when resume is enabled).
3. Per **source** — every data disk AND every pool mount (`/mnt/cache`, …; the
   target mount is never a source) — one
   `rsync -aHAX --numeric-ids --partial-dir=.rsync-partial --link-dest=<last successful run>/fs`
   runs concurrently into the SAME `fs/` subtree (`max_jobs` caps concurrency,
   `bwlimit` throttles). One shared `--link-dest` is the point: it makes the
   mover-moved file a hard link (delta ≈ 0). There is deliberately **no**
   `--delete` here – a job must never remove files other sources bring in.
   A share filter applies the same `--exclude` set to every job and to the
   sweep: `skip_shares`, `shareUseCache=only` from `/boot/config/shares/<share>.cfg`
   (the key is `shareUseCache` on the server, older installs write `share_use`),
   and an array-reality check (a share that exists on no `/mnt/diskN` is never
   covered by this plugin → warning banner only).
4. After **all** transfers a guarded orphan-sweep mirrors deletions per share:
   union of the sources vs. the snapshot content; entries present nowhere
   anymore get removed (`find`+`comm`+`rm`, deliberately not rsync `--delete`,
   which from an empty helper source would empty the whole share). Guards: only
   when the run is `success`, only inside the staging copy, every source still
   mounted, and never more than 50 % of a share's entries (then the sweep
   refuses and the run is demoted to `partial`).
5. Transient rsync errors (10/11/12/30) retry up to 3 times with backoff;
   exit 24 (vanished source files) counts as success; fatal codes abort.
6. On success: `.runmeta.json` written, run atomically renamed into `runs/`,
   `latest`/`perdisk/`/`pershare/` updated, retention applied (count + free-space
   guard, pinned runs kept).
7. Live progress lives in `/var/run/arraybackup/status.json` (RAM); run
   summaries in `/boot/config/plugins/arraybackup/logs/` (flash-friendly,
   rotated at 1 MB).

## Test plan

| Scenario | Steps | Expectation |
|---|---|---|
| Dry run | enable dry run, start | rsync `-n`, **no** run directory left in `runs/` or `.ab-staging/` |
| Snapshot chain | 2 runs, then `stat runs/r-*/fs/<share>/<same file>` | same inode = hard link, delta size ≈ changes only |
| **mover test** | run A, mover moves a file cache → disk, run B | same inode in `fs/`, its bytes are NOT in the delta (delta ≈ 0) — the core goal |
| file on disk **and** pool | one file on `/mnt/disk1` and `/mnt/cache` | appears exactly **once** in `fs/` (no duplicate) |
| deleted on disk/pool | delete a file, run | after the sweep the entry is gone from the new snapshot |
| pool-only share | share `Cache → Backup` (exists on no disk) | **not** in the snapshot, info banner names it (`orphan_info`) |
| skipped share | `skip_shares=docker` | not transferred; the sweep never deletes it either |
| layout switch | first run after this update | copies completely (old per-disk runs cannot link into `fs/`); the next run is incremental |
| resume, legacy run | abort an old-layout run, update, start | legacy staged run is not resumed (dropped); fresh `fs/`-run starts |
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
| `src/ArrayBackup.page` | WebUI with `.page` header (`Menu="user"` → icon grid "User Utilities", `Icon="hard-disk"`); tabs: Backups, Array browser, Disk history, Configuration; single de/en string table |
| `src/include/hard-disk.png` | plugin icon for the User-Utilities tile, embedded base64 over its raw bytes (`.gitattributes`: `*.png -text`) |
| `src/install.sh` | post-install script (directories, default config, cron on flash) |
| `src/include/ajax.php` | JSON API (`config-get/-save`, `start`, `stop`, `status`, `runs`, `ls` [paged], `pin`, `delete-run`) |
| `src/include/engine.sh` | backup engine (parallel rsync, staging + atomic promotion, retries, retention, log rotation) |

## Known limits / future ideas

- v1 mirrors **disks**, not shares (a share union view is conceivable)
- no checksum verification, no notifications
- retention by count, not a GFS scheme
