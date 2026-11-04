# back – unRAID ArrayBackup plugin

This workspace contains a single plugin:

- [`unraid-array-backup/`](unraid-array-backup/README.md) – ArrayBackup:
  parallel per-disk `rsync` backups of the unRAID array onto a fast local
  target (RAID0), with atomic snapshot promotion, staged resume, retries,
  retention/pinning and a Settings-page WebUI.

Build the plugin with `unraid-array-backup/build.sh` (output:
`unraid-array-backup/arraybackup.plg`, validated by
`tools/validate_plg.py` as a build gate).

Documentation, installation and test plan:
**[unraid-array-backup/README.md](unraid-array-backup/README.md)** (English).
