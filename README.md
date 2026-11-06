# back – unRAID ArrayBackup plugin

This workspace contains a single plugin:

- [`unraid-array-backup/`](unraid-array-backup/README.md) – ArrayBackup:
  parallel `rsync` backups of every array data disk **and pool mount** into one
  merged snapshot tree (`fs/`) on a fast local target (e.g. RAID0), with atomic
  snapshot promotion, guarded orphan-sweep, staged resume, retries,
  retention/pinning, browser restore and a User-Utilities WebUI.

Build the plugin with `unraid-array-backup/build.sh` (output:
`unraid-array-backup/arraybackup.plg`, validated by
`tools/validate_plg.py` as a build gate).

Documentation, installation and test plan:
**[unraid-array-backup/README.md](unraid-array-backup/README.md)** (English).
